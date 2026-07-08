import Foundation

/// Pure split math + the client-side balance check. Kept out of views so it's unit-testable.
enum SplitMath {
    static let tolerance = Decimal(string: "0.01")!

    private static func cents(_ amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * 100).rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0,
                                   raiseOnExactness: false, raiseOnOverflow: false,
                                   raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }

    private static func money(_ cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    static func paidSum(_ splits: [SplitDraft]) -> Decimal {
        splits.reduce(Decimal(0)) { $0 + $1.paidShare }
    }

    static func owedSum(_ splits: [SplitDraft]) -> Decimal {
        splits.reduce(Decimal(0)) { $0 + $1.owedShare }
    }

    /// `paid` and `owed` must each equal `amount` within ±0.01.
    static func isBalanced(amount: Decimal, splits: [SplitDraft]) -> Bool {
        abs(paidSum(splits) - amount) <= tolerance && abs(owedSum(splits) - amount) <= tolerance
    }

    private static func paid(_ identifier: String, payer: String, amount: Decimal) -> Decimal {
        identifier == payer ? amount : 0
    }

    /// Equal split: `payer` paid the full amount; everyone (incl. the payer) owes an equal share.
    /// Remainder pennies are assigned to the earliest participants so owed sums to the amount exactly.
    static func equalSplit(amount: Decimal, payer: String, participants: [String]) -> [SplitDraft] {
        let people = participants.isEmpty ? [payer] : participants
        let total = cents(amount)
        let n = people.count
        let base = total / n
        let remainder = total - base * n
        return people.enumerated().map { index, identifier in
            let owedCents = base + (index < remainder ? 1 : 0)
            return SplitDraft(
                userIdentifier: identifier,
                paidShare: paid(identifier, payer: payer, amount: amount),
                owedShare: money(owedCents)
            )
        }
    }

    /// Distribute `amount` proportional to per-participant weights (percentages or share counts);
    /// falls back to equal when all weights are zero. Rounding drift is spread so owed sums exactly.
    static func weightedSplit(amount: Decimal, payer: String, participants: [String],
                              weights: [String: Decimal]) -> [SplitDraft] {
        let people = participants.isEmpty ? [payer] : participants
        let ws = people.map { max(weights[$0] ?? 0, 0) }
        let totalWeight = ws.reduce(Decimal(0), +)
        guard totalWeight > 0 else { return equalSplit(amount: amount, payer: payer, participants: people) }
        var owed = ws.map { cents(amount * $0 / totalWeight) }
        var drift = cents(amount) - owed.reduce(0, +)
        var i = 0
        while drift != 0 && !owed.isEmpty {
            owed[i % owed.count] += drift > 0 ? 1 : -1
            drift += drift > 0 ? -1 : 1
            i += 1
        }
        return people.enumerated().map { index, identifier in
            SplitDraft(userIdentifier: identifier,
                       paidShare: paid(identifier, payer: payer, amount: amount),
                       owedShare: money(owed[index]))
        }
    }

    /// Equal base split, then per-participant +/- adjustments (owed = base + adjustment).
    static func adjustmentSplit(amount: Decimal, payer: String, participants: [String],
                                adjustments: [String: Decimal]) -> [SplitDraft] {
        let people = participants.isEmpty ? [payer] : participants
        let totalAdj = people.reduce(Decimal(0)) { $0 + (adjustments[$1] ?? 0) }
        let base = equalSplit(amount: amount - totalAdj, payer: payer, participants: people)
        return people.map { identifier in
            let baseOwed = base.first { $0.userIdentifier == identifier }?.owedShare ?? 0
            return SplitDraft(userIdentifier: identifier,
                              paidShare: paid(identifier, payer: payer, amount: amount),
                              owedShare: baseOwed + (adjustments[identifier] ?? 0))
        }
    }

    /// Reimbursement (the inverse of an expense): `payer` *received* the full amount (a windfall) and
    /// splits it equally - so the payer ends up owing the others their shares. Encoded as an equal
    /// split with each person's paid/owed swapped, which flips every balance while staying summed to
    /// the amount. Net: the recipient owes; everyone else is owed their share ("gets back").
    static func reimbursementSplit(amount: Decimal, payer: String, participants: [String]) -> [SplitDraft] {
        equalSplit(amount: amount, payer: payer, participants: participants).map {
            SplitDraft(userIdentifier: $0.userIdentifier, paidShare: $0.owedShare, owedShare: $0.paidShare)
        }
    }

    /// Itemized: each person owes the sum of items assigned to them; any unassigned remainder
    /// (e.g. tax/tip) is split equally.
    static func itemizedSplit(amount: Decimal, payer: String, participants: [String],
                              assigned: [String: Decimal]) -> [SplitDraft] {
        let people = participants.isEmpty ? [payer] : participants
        let assignedTotal = people.reduce(Decimal(0)) { $0 + (assigned[$1] ?? 0) }
        let remainder = equalSplit(amount: amount - assignedTotal, payer: payer, participants: people)
        return people.map { identifier in
            let rem = remainder.first { $0.userIdentifier == identifier }?.owedShare ?? 0
            return SplitDraft(userIdentifier: identifier,
                              paidShare: paid(identifier, payer: payer, amount: amount),
                              owedShare: (assigned[identifier] ?? 0) + rem)
        }
    }
}

/// Marks an expense as a reimbursement (windfall split). Like `SettleUp`, it's flagged via the
/// category so the detail view can render "gets back" phrasing.
enum Reimbursement {
    static let category = "Reimbursement"
}

/// Splitwise-style presentation: collapse expenses older than the most recent settle-up.
enum SettleUp {
    static let category = "Settle-up"

    /// `expenses` must be sorted newest-first. Returns the visible prefix (through the most recent
    /// settle-up, inclusive) and how many older expenses were collapsed.
    static func collapseOlder(_ expenses: [Expense]) -> (visible: [Expense], collapsed: Int) {
        guard let index = expenses.firstIndex(where: { $0.category == category }) else {
            return (expenses, 0)
        }
        let visible = Array(expenses[...index])
        return (visible, expenses.count - visible.count)
    }
}
