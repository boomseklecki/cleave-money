import SwiftData
import SwiftUI

/// Connect a bank via SimpleFIN (paste the setup token), then a review step: set the last-4 on each account
/// and resolve any that look like ones you already have via Plaid/import - keep separate, or merge into the
/// existing account choosing which source feeds it going forward. No SDK, no OAuth.
struct SimpleFinLinkView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private typealias Match = Components.Schemas.SimpleFinAccountMatch
    private typealias Candidate = Components.Schemas.SimpleFinCandidate
    private typealias Acct = Components.Schemas.AccountResponse
    private typealias Source = Components.Schemas.TransactionSource

    @State private var token = ""
    @State private var connecting = false
    @State private var errorMessage: String?
    @State private var notices: [String] = []

    // Review phase (populated after a successful connect).
    @State private var accounts: [Acct] = []
    @State private var matches: [Match] = []
    @State private var masks: [String: String] = [:]            // account_id -> last-4 text
    @State private var chosenCandidate: [String: String] = [:]  // sf account_id -> target account_id ("" = keep new)
    @State private var chosenSource: [String: Source] = [:]     // sf account_id -> primary source
    @State private var applying = false

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var reviewing: Bool { !accounts.isEmpty }

    var body: some View {
        Form {
            if reviewing {
                reviewSection
            } else {
                tokenSection
            }
        }
        .navigationTitle(reviewing ? "Review accounts" : "Connect via SimpleFIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(connecting || applying)
            }
            ToolbarItem(placement: .confirmationAction) {
                if reviewing {
                    Button("Done") { Task { await apply() } }.disabled(applying)
                } else {
                    Button("Connect") { Task { await connect() } }
                        .disabled(connecting || trimmedToken.isEmpty)
                }
            }
        }
        .overlay {
            if connecting || applying {
                ProgressView(connecting ? "Connecting…" : "Saving…")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .interactiveDismissDisabled(connecting || applying)
    }

    // MARK: token entry

    private var tokenSection: some View {
        SwiftUI.Group {
            Section {
                TextField("Paste your SimpleFIN setup token", text: $token, axis: .vertical)
                    .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(connecting)
            } header: {
                Text("Setup token")
            } footer: {
                Text("Get a setup token at beta-bridge.simplefin.org, then paste it here. Your bank data flows "
                     + "through SimpleFIN read-only; the token is stored encrypted on your server.")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
    }

    // MARK: review + resolve

    private var reviewSection: some View {
        SwiftUI.Group {
            if !notices.isEmpty {
                Section("Heads up") {
                    ForEach(notices, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
            ForEach(accounts, id: \.id) { acct in
                Section {
                    HStack {
                        Text("Last 4")
                        Spacer()
                        TextField("1234", text: maskBinding(acct.id))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    if let match = matchFor(acct.id) {
                        Picker("This account", selection: candidateBinding(acct.id, match: match)) {
                            Text("Keep as new account").tag("")
                            ForEach(match.candidates, id: \.account_id) { c in
                                Text(candidateLabel(c)).tag(c.account_id)
                            }
                        }
                        if let cand = chosenCandidateObject(acct.id, match: match) {
                            Picker("Feed going forward", selection: sourceBinding(acct.id)) {
                                Text(keepLabel(cand.source)).tag(sourceEnum(cand.source))
                                Text("SimpleFIN (live)").tag(Source.simplefin)
                            }
                            if cand.source == "plaid" {
                                Text("Plaid bills per institution, not per account, so keeping both is fine.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(acct.institution_name ?? acct.name)
                }
            }
        }
    }

    // MARK: helpers

    private func matchFor(_ id: String) -> Match? { matches.first { $0.account_id == id } }

    private func chosenCandidateObject(_ id: String, match: Match) -> Candidate? {
        guard let cid = chosenCandidate[id], !cid.isEmpty else { return nil }
        return match.candidates.first { $0.account_id == cid }
    }

    private func candidateLabel(_ c: Candidate) -> String {
        let tail = c.mask.map { " ····\($0)" } ?? ""
        let via = c.source == "plaid" ? "Plaid" : "import"
        return "\(c.name)\(tail) · via \(via)\((c.strong ?? false) ? " · likely" : "")"
    }

    private func sourceEnum(_ s: String) -> Source { s == "plaid" ? .plaid : .manual }
    private func keepLabel(_ s: String) -> String { s == "plaid" ? "Keep Plaid" : "Keep imported" }

    private func maskBinding(_ id: String) -> Binding<String> {
        Binding(get: { masks[id] ?? "" },
                set: { masks[id] = String($0.filter(\.isNumber).suffix(4)) })
    }

    private func candidateBinding(_ id: String, match: Match) -> Binding<String> {
        Binding(get: { chosenCandidate[id] ?? "" }, set: { newVal in
            chosenCandidate[id] = newVal
            if !newVal.isEmpty, chosenSource[id] == nil {
                // Default: upgrade an imported account to live SimpleFIN, else keep the (Plaid) feed.
                let cand = match.candidates.first { $0.account_id == newVal }
                chosenSource[id] = cand?.source == "plaid" ? .plaid : .simplefin
            }
        })
    }

    private func sourceBinding(_ id: String) -> Binding<Source> {
        Binding(get: { chosenSource[id] ?? .simplefin }, set: { chosenSource[id] = $0 })
    }

    // MARK: actions

    private func connect() async {
        connecting = true; errorMessage = nil; notices = []
        defer { connecting = false }
        do {
            let response = try await env.simplefinSlow(context).connect(setupToken: trimmedToken)
            notices = response.warnings ?? []
            if let err = response.error, !err.isEmpty { notices.append(err) }
            accounts = response.accounts
            matches = response.matches ?? []
            for a in accounts { masks[a.id] = a.mask ?? "" }
            if accounts.isEmpty { dismiss() }  // nothing to review
        } catch {
            errorMessage = "Couldn't connect. Check the setup token and try again."
        }
    }

    private func apply() async {
        applying = true
        defer { applying = false }
        let sf = env.simplefin(context)
        for acct in accounts {  // persist any edited last-4
            let entered = (masks[acct.id] ?? "").trimmingCharacters(in: .whitespaces)
            if entered != (acct.mask ?? ""), let aid = UUID(uuidString: acct.id) {
                try? await sf.setMask(accountId: aid, mask: entered.isEmpty ? nil : entered)
            }
        }
        for match in matches {  // apply merges the user chose
            guard let cid = chosenCandidate[match.account_id], !cid.isEmpty,
                  let incoming = UUID(uuidString: match.account_id), let target = UUID(uuidString: cid)
            else { continue }
            try? await sf.merge(incoming: incoming, target: target,
                                primarySource: chosenSource[match.account_id] ?? .simplefin)
        }
        let accountsRepo = env.accounts(context)
        try? await accountsRepo.refreshAccounts()
        try? await accountsRepo.refreshTransactions()
        dismiss()
    }
}
