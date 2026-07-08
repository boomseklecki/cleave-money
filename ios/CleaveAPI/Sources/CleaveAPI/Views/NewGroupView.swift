import SwiftUI
import SwiftData

/// Create a group. Self-hosted by default; when Splitwise is connected you can create it **on Splitwise**
/// (propagated, so it shows up for everyone you add). Splitwise groups can carry a type (trip / apartment / ...).
struct NewGroupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var backendType: BackendType = .selfHosted
    @State private var groupType = ""
    @State private var creating = false
    @State private var errorText: String?

    /// Common Splitwise group types (free-form on the API; these are the picker presets).
    private let types = ["", "trip", "home", "apartment", "house", "couple", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).autocorrectionDisabled()
                }
                if env.splitwiseConnected {
                    Section {
                        Picker("Where", selection: $backendType) {
                            Text("Self-hosted").tag(BackendType.selfHosted)
                            Text("Splitwise").tag(BackendType.splitwise)
                        }
                        if backendType == .splitwise {
                            Picker("Type", selection: $groupType) {
                                ForEach(types, id: \.self) { t in
                                    Text(t.isEmpty ? "None" : t.capitalized).tag(t)
                                }
                            }
                        }
                    } footer: {
                        Text(backendType == .splitwise
                             ? "Creates the group on Splitwise. Add people from Members afterward."
                             : "A local group only you (and people you add) can see.")
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .errorAlert($errorText)
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = groupType.isEmpty ? nil : groupType
        creating = true
        Task {
            defer { creating = false }
            do {
                try await env.groups(context).create(
                    name: trimmed, backendType: backendType, groupType: type)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
