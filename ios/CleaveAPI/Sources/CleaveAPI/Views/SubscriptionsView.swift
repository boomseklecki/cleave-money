import SwiftUI
import SwiftData

/// A Rocket Money–style overview of recurring charges, detected on-device across all categories. Shows
/// the estimated annual cost, upcoming predicted charges, and each subscription with its brand logo, per-
/// period amount, annual cost, and a price-increase flag. Reached from Settings → Subscriptions.
struct SubscriptionsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]
    @Query private var rules: [SubscriptionRule]
    @Query private var decisions: [SuggestionDecision]

    @State private var brandModel = BrandModel()
    @State private var errorText: String?

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }

    var body: some View {
        // Detect once per render (not inside the row builders), honoring the user's manual rules.
        let result = SubscriptionDetector.analyze(transactions: transactions, expenses: expenses,
                                                  lookup: lookup, me: env.currentUser?.identifier, rules: rules)
        let subs = result.subscriptions
        // Hide candidates the user dismissed in the Inbox (or here) - same decision store the Inbox reads.
        let blocked = Set(decisions.filter(\.isActive).map(\.key))
        let candidates = result.candidates.filter {
            !blocked.contains("sub:\($0.id)") && !blocked.contains("merchant:\($0.id)")
        }
        let annual = subs.reduce(Decimal(0)) { $0 + $1.annualCost }
        // Upcoming = predicted charges from today through the next 30 days. A nextDate in the past means
        // the charge already lapsed (stale data) - don't show it as "upcoming".
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let windowEnd = cal.date(byAdding: .day, value: 30, to: today)!
        let upcoming = subs
            .filter { $0.nextDate >= today && $0.nextDate <= windowEnd }
            .sorted { $0.nextDate < $1.nextDate }

        return List {
            if subs.isEmpty && candidates.isEmpty {
                ContentUnavailableView("No Subscriptions Found", systemImage: "repeat",
                    description: Text("Recurring charges are detected from your transactions. Sync a bank "
                                      + "or add a few months of activity, then check back."))
            }
            if !subs.isEmpty {
                Section {
                    VStack(spacing: 4) {
                        Text(annual.formatted(.currency(code: "USD"))).font(.largeTitle).fontWeight(.bold)
                        Text("estimated per year").font(.subheadline).foregroundStyle(.secondary)
                        Text("\((annual / 12).formatted(.currency(code: "USD")))/mo · \(subs.count) "
                             + "subscription\(subs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }

                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(upcoming) { upcomingCard($0) }
                            }
                            .padding(.horizontal).padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets())   // let the strip bleed to the edges; cards inset via padding
                    }
                }

                Section("Subscriptions") {
                    ForEach(subs) { sub in
                        NavigationLink {
                            SubscriptionDetailView(subscription: sub, brand: brandModel.brand(for: sub))
                        } label: {
                            row(sub)
                        }
                        .swipeActions {
                            Button("Not a Subscription", systemImage: "xmark.circle", role: .destructive) {
                                addRule(merchantKey: sub.id, amount: sub.latestAmount,
                                        displayName: brandModel.brand(for: sub).name, isSubscription: false)
                            }
                        }
                    }
                }
            }

            if !candidates.isEmpty {
                Section {
                    ForEach(candidates) { c in
                        candidateRow(c)
                            .swipeActions(edge: .trailing) {
                                Button("Dismiss", role: .destructive) { decide(c, forMerchant: false) }
                                Button("Never") { decide(c, forMerchant: true) }.tint(.gray)
                            }
                    }
                } header: {
                    Text("Possible Subscriptions")
                } footer: {
                    Text("Recurring charges we didn't auto-detect. Tap ＋ to track one, or swipe to dismiss "
                         + "or mark it never a subscription.")
                }
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SubscriptionRulesView() } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
        }
        .task {
            await brandModel.resolve(subs.map { ($0.id, $0.displayName, String?.none) }
                                     + candidates.map { ($0.id, $0.displayName, String?.none) })
        }
        .errorAlert($errorText)
    }

    @ViewBuilder
    private func candidateRow(_ c: SubscriptionCandidate) -> some View {
        let brand = brandModel.brand(key: c.id, displayName: c.displayName)
        HStack(spacing: 12) {
            AvatarView(url: brand.logoURL, name: brand.name, size: 40, systemImage: "repeat")
            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name).lineLimit(1)
                Text("~\(c.amount.formatted(.currency(code: "USD")))"
                     + (c.cadence.map { " · \($0.label.lowercased())" } ?? "")
                     + " · \(c.occurrences) charges")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                addRule(merchantKey: c.id, amount: c.amount, displayName: brand.name, isSubscription: true)
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        }
    }

    private func addRule(merchantKey: String, amount: Decimal, displayName: String, isSubscription: Bool) {
        context.insert(SubscriptionRule(merchantKey: merchantKey, amount: amount,
                                        isSubscription: isSubscription, displayName: displayName))
        do { try context.save(); env.pushSuggestionsSync(context) } catch { errorText = errorMessage(error) }
    }

    /// Decline a candidate through the same path the Inbox uses, so the two areas stay in lockstep:
    /// Dismiss hides this candidate (and stops the Inbox nag); Never also excludes it from detection.
    private func decide(_ c: SubscriptionCandidate, forMerchant: Bool) {
        let name = brandModel.brand(key: c.id, displayName: c.displayName).name
        let sug = Suggestion(id: "sub:\(c.id)", kind: .subscription, title: name, subtitle: "",
                             icon: "repeat", acceptLabel: "Track", merchantKey: c.id, amount: c.amount)
        do { try env.suggestions(context).dismiss(sug, forMerchant: forMerchant) }
        catch { errorText = errorMessage(error) }
    }

    /// A compact card for the horizontal "Upcoming" gallery: logo, name, amount, and due date.
    private func upcomingCard(_ sub: Subscription) -> some View {
        let brand = brandModel.brand(for: sub)
        return NavigationLink {
            SubscriptionDetailView(subscription: sub, brand: brand)
        } label: {
            VStack(spacing: 6) {
                AvatarView(url: brand.logoURL, name: brand.name, size: 44, systemImage: "repeat")
                Text(brand.name).font(.caption).lineLimit(1)
                Text(sub.latestAmount.formatted(.currency(code: sub.currency)))
                    .font(.caption).fontWeight(.medium).monospacedDigit()
                Text(sub.nextDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 96)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ sub: Subscription) -> some View {
        let brand = brandModel.brand(for: sub)
        HStack(spacing: 12) {
            AvatarView(url: brand.logoURL, name: brand.name, size: 40, systemImage: "repeat")
            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(sub.latestAmount.formatted(.currency(code: sub.currency)))/\(sub.cadence.unit)")
                    if sub.isShared {
                        Text("· your share").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if sub.increased, let from = sub.increaseFrom {
                    Label("Up from \(from.formatted(.currency(code: sub.currency)))", systemImage: "arrow.up.right")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            Text("\(sub.annualCost.formatted(.currency(code: sub.currency)))/yr")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
