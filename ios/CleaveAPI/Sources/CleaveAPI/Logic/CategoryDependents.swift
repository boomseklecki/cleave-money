import Foundation

enum CategorySource { case bank, splitwise }

/// One source category (a Plaid bank label or a Splitwise name) that resolves to a canonical category.
struct CategoryDependent: Identifiable, Hashable {
    let raw: String
    let source: CategorySource
    var id: String { raw }
    var label: String { source == .bank ? PlaidCategory.humanized(raw) : raw }
    var icon: String { source == .bank ? "building.columns" : "person.2" }
}

/// The reverse of category mapping: for each canonical category, every source label that currently
/// lands on it - via a manual `category_map` override **or** the built-in deterministic Plaid/Splitwise
/// maps. Drawn from the user's actual data (distinct transaction/expense categories) plus any override
/// rows, so e.g. "Dining" lists `Food And Drink Coffee`, `Liquor`, ... not just explicit remaps.
enum CategoryDependents {
    static func grouped(transactions: [Transaction], expenses: [Expense],
                        categoryMaps: [CategoryMap]) -> [String: [CategoryDependent]] {
        let lookup = CategoryMapping.lookup(categoryMaps)
        var byCanonical: [String: [CategoryDependent]] = [:]
        var seen = Set<String>()

        func add(_ raw: String?, _ source: CategorySource) {
            guard let raw, !raw.isEmpty, seen.insert(raw).inserted,
                  let canonical = CategoryMapping.canonical(raw, lookup: lookup) else { return }
            byCanonical[canonical, default: []].append(CategoryDependent(raw: raw, source: source))
        }

        for t in transactions where t.source == .plaid || t.source == .simplefin { add(t.category, .bank) }
        for e in expenses where e.splitwiseExpenseId != nil {
            if e.category != SettleUp.category && e.category != Reimbursement.category { add(e.category, .splitwise) }
        }
        // Override rows whose label isn't present in current data (still counts as a dependency).
        for m in categoryMaps {
            let isBank = m.rawCategory == m.rawCategory.uppercased() && m.rawCategory.contains("_")
            add(m.rawCategory, isBank ? .bank : .splitwise)
        }

        for key in byCanonical.keys { byCanonical[key]?.sort { $0.label < $1.label } }
        return byCanonical
    }

    static func of(_ canonical: String, transactions: [Transaction], expenses: [Expense],
                   categoryMaps: [CategoryMap]) -> [CategoryDependent] {
        grouped(transactions: transactions, expenses: expenses, categoryMaps: categoryMaps)[canonical] ?? []
    }
}
