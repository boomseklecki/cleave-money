import SwiftUI
import SwiftData

/// One subscription's detail: brand header, cadence + annual estimate, predicted next charge, a price-
/// increase note, and the charge history (each drills into the underlying transaction or expense). Tapping
/// the brand avatar opens a category picker that recategorizes every transaction behind the subscription.
struct SubscriptionDetailView: View {
    let subscription: Subscription
    let brand: Brand

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var categoryMaps: [CategoryMap]

    @State private var showingCategoryPicker = false
    @State private var applying = false
    @State private var errorText: String?

    private func currency(_ value: Decimal) -> String {
        value.currency(subscription.currency)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Button { showingCategoryPicker = true } label: {
                        AvatarView(url: brand.logoURL, name: brand.name, size: 64, systemImage: "repeat")
                    }
                    .buttonStyle(.plain)
                    .disabled(applying)
                    Text(brand.name).font(.title2).fontWeight(.semibold)
                    Text("\(currency(subscription.latestAmount))/\(subscription.cadence.unit) · "
                         + subscription.cadence.label)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section {
                LabeledContent("Estimated yearly", value: currency(subscription.annualCost))
                LabeledContent("Next charge",
                               value: subscription.nextDate.dateOnly())
                if subscription.increased, let from = subscription.increaseFrom {
                    LabeledContent("Price change") {
                        Label("Up from \(currency(from))", systemImage: "arrow.up.right")
                            .foregroundStyle(.red)
                    }
                }
                if subscription.isShared {
                    LabeledContent("Tracked as", value: "Shared expense (your share)")
                }
            }

            Section("Charges") {
                ForEach(subscription.charges) { charge in
                    NavigationLink {
                        switch charge.source {
                        case .transaction(let t): LazyView(TransactionDetailView(transaction: t))
                        case .expense(let e): LazyView(ExpenseDetailView(expense: e))
                        }
                    } label: {
                        HStack {
                            Text(charge.date.dateOnly())
                            Spacer()
                            Text(currency(charge.amount)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: currentCategory, subject: brand.name) { apply($0) }
        }
        .errorAlert($errorText)
    }

    /// The effective category of the newest underlying transaction (the picker's starting point).
    private var currentCategory: String? {
        let lookup = CategoryMapping.lookup(categoryMaps)
        for charge in subscription.charges {
            if case .transaction(let t) = charge.source {
                return CategoryMapping.effectiveCategory(for: t, lookup: lookup)
            }
        }
        return nil
    }

    /// Apply the picked category to every transaction behind this subscription (transactions only; a shared
    /// expense charge keeps its own category). No batch endpoint - loop the per-transaction override.
    private func apply(_ category: String) {
        let ids: [UUID] = subscription.charges.compactMap { charge in
            if case .transaction(let t) = charge.source { return t.id }
            return nil
        }
        Task {
            applying = true
            defer { applying = false }
            do {
                try await env.accounts(context).setCategoryOverride(ids: ids, category: category)
            } catch {
                errorText = errorMessage(error)
            }
        }
    }
}
