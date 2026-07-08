import Foundation

/// Combined "household" budgeting: a shared spend goal counts BOTH partners' spending toward one limit.
///
/// Only **shared-group expenses** count - expenses in a local or Splitwise group both partners belong to.
/// Solo, unsplit Plaid transactions never enter here (they're excluded by construction, and a transaction
/// linked to a shared expense is already represented by that expense in the analytics pipeline). Each
/// member's contribution is their own owed-share, item-aware via `ItemizedSpend`, canonicalized
/// **deterministically** (empty `lookup`, so the per-user category override is skipped) - that's how both
/// partners independently compute the *same* category for the same expense. Both apps already cache every
/// member's `Split` + `ExpenseItem`, so this is computed locally with no publishing and no backend.
enum HouseholdBudget {
    /// A participant in a household budget - the viewer ("You") plus each connected partner.
    struct Member: Hashable {
        let identifier: String
        let label: String   // "You" for the viewer, else the partner's display name
        let isViewer: Bool
    }

    /// One category's combined spend, split by who incurred it.
    struct Spend {
        var mine: Decimal = 0
        var partners: [String: Decimal] = [:]  // partner identifier → their owed-share spend
        var partnerTotal: Decimal { partners.values.reduce(0, +) }
        var combined: Decimal { mine + partnerTotal }
    }

    /// Group ids whose cached membership contains the viewer **and** at least one partner - the groups whose
    /// expenses are "shared" for this household.
    static func sharedGroupIds(viewer: String, partners: Set<String>,
                               membersByGroup: [UUID: Set<String>]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (gid, members) in membersByGroup where members.contains(viewer)
            && !members.isDisjoint(with: partners) {
            ids.insert(gid)
        }
        return ids
    }

    /// `[groupId: {memberIdentifier}]` from cached `GroupMember` rows.
    static func membership(_ members: [GroupMember]) -> [UUID: Set<String>] {
        var out: [UUID: Set<String>] = [:]
        for m in members { out[m.groupId, default: []].insert(m.userIdentifier) }
        return out
    }

    /// Combined household spend per canonical category for `month`, over shared-group expenses, split by
    /// member. One pass over expenses; each member's per-category owed share comes from `ItemizedSpend`.
    static func combinedByCategory(month: Date, expenses: [Expense], sharedGroupIds: Set<UUID>,
                                   viewer: String, partners: Set<String>) -> [String: Spend] {
        let cal = SpendingAnalytics.spendCalendar
        let target = SpendingAnalytics.monthStart(month, cal)
        var out: [String: Spend] = [:]
        for e in expenses where sharedGroupIds.contains(e.groupId)
            && SpendingAnalytics.monthStart(e.date, cal) == target {
            for c in ItemizedSpend.categoryContributions(for: e, me: viewer, lookup: [:]) {
                out[c.category, default: Spend()].mine += c.amount
            }
            for p in partners {
                for c in ItemizedSpend.categoryContributions(for: e, me: p, lookup: [:]) {
                    out[c.category, default: Spend()].partners[p, default: 0] += c.amount
                }
            }
        }
        return out
    }

    /// Combined household spend in a single `category` for `month` (the per-category slice of
    /// `combinedByCategory`, computed directly for callers that need just one).
    static func combined(category: String, month: Date, expenses: [Expense], sharedGroupIds: Set<UUID>,
                         viewer: String, partners: Set<String>) -> Spend {
        combinedByCategory(month: month, expenses: expenses, sharedGroupIds: sharedGroupIds,
                           viewer: viewer, partners: partners)[category] ?? Spend()
    }

    /// The contributing rows behind a household budget for `category` across the inclusive month range
    /// `start...end`: one row per (shared-group expense or item) × member with a non-zero share, tagged with
    /// who incurred it. Each carries its source `Expense` so the drill-through can open `ExpenseDetailView`.
    static func contributors(category: String, from start: Date, to end: Date, expenses: [Expense],
                             sharedGroupIds: Set<UUID>, household: [Member]) -> [Contributor] {
        let cal = SpendingAnalytics.spendCalendar
        let lo = SpendingAnalytics.monthStart(start, cal)
        let hi = SpendingAnalytics.monthStart(end, cal)
        var rows: [Contributor] = []
        for e in expenses where sharedGroupIds.contains(e.groupId) {
            let m = SpendingAnalytics.monthStart(e.date, cal)
            guard m >= lo, m <= hi else { continue }
            for member in household {
                for d in ItemizedSpend.detailed(for: e, me: member.identifier, lookup: [:])
                where d.category == category && d.amount > 0 {
                    let label = d.itemId
                        .flatMap { id in e.items.first { $0.id == id } }
                        .map { "\(e.details) · \($0.name)" } ?? e.details
                    rows.append(Contributor(
                        id: "\(e.id.uuidString)-\(d.itemId?.uuidString ?? "base")-\(member.identifier)",
                        expense: e, label: label, date: e.date, amount: d.amount, who: member.label,
                        byViewer: member.isViewer))
                }
            }
        }
        return rows.sorted { $0.amount > $1.amount }
    }

    /// One drill-through row behind a household budget total.
    struct Contributor: Identifiable {
        let id: String
        let expense: Expense
        let label: String
        let date: Date
        let amount: Decimal
        let who: String        // member label ("You" / partner name)
        let byViewer: Bool
    }
}
