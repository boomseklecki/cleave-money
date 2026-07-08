import Foundation

/// A candidate transaction for linking to an expense, with a 0...1 heuristic confidence.
struct TransactionMatch: Identifiable {
    let transaction: Transaction
    let score: Double
    var id: UUID { transaction.id }
}

/// Pure, on-device ranking of which bank/manual transactions best match an expense - the basis for the
/// "link a transaction" suggestions. Deterministic (no model needed); the Foundation Models layer in
/// `TransactionMatchModel` can re-rank the top of this list when Apple Intelligence is available.
///
/// Signals: amount closeness (a shared bill is paid in full from one account, so we compare against both
/// the expense's full cost *and* the payer's `paidShare`), date proximity, and merchant/description token
/// overlap. Merchant-name overlap is usually zero (a bank charge string vs a Splitwise label), so amount +
/// date carry the match - and they're penalized **exponentially**: a non-recurring match must be near-exact
/// and near-same-day, while a recurring bill (a strong signal that this *is* the charge, and one that
/// legitimately varies a few days/cents between posting and the Splitwise entry) tolerates more slack.
enum TransactionMatcher {
    /// Amount pre-gate: skip an obvious non-match before scoring (an exponential amount score this low can't
    /// reach the link threshold anyway). Relative, so it scales with the bill size.
    private static let minAmountScore = 0.6
    /// Exponential decay rates - steeper (bigger k) when NOT recurring.
    private static let kAmountRecurring = 12.0, kAmountStrict = 60.0   // per unit relative amount difference
    private static let kDateRecurring = 0.05, kDateStrict = 0.12       // per day of difference
    private static let recurringBonus = 0.05
    /// Signal weights - amount + date carry the match (0.55 + 0.35 = 0.90, so an exact same-day match clears
    /// the 0.85 Strict floor without any name overlap); merchant name is a small positive nudge when present.
    private static let wAmount = 0.55, wDate = 0.35, wName = 0.10

    /// Human-readable confidence band for a match score - shared by the link picker and the confirm sheet.
    static func confidenceLabel(_ score: Double) -> String {
        switch score {
        case 0.8...: return "Strong match"
        case 0.5..<0.8: return "Likely match"
        default: return "Possible match"
        }
    }

    /// Words that carry no matching signal (payment plumbing / legal suffixes).
    private static let stopWords: Set<String> = [
        "the", "and", "for", "payment", "pmt", "ach", "autopay", "auto", "bill", "online",
        "llc", "inc", "co", "corp", "ltd", "card", "purchase", "pos", "debit", "credit",
    ]

    static func transactionCandidates(for expense: Expense, transactions: [Transaction], expenses: [Expense],
                           me: String?, limit: Int = 8, windowDays: Int = 21) -> [TransactionMatch] {
        // Exclude transactions already linked to another expense.
        var linked = Set<UUID>()
        for e in expenses where e.id != expense.id {
            if let tid = e.transactionId { linked.insert(tid) }
        }

        let full = nsDouble(expense.amount)
        let mySplit = me.flatMap { id in expense.splits.first { $0.userIdentifier == id } }
        let myPaid: Double? = mySplit.map { nsDouble($0.paidShare) }
        let expenseTokens = tokens(expense.details)
        let recurring = expense.repeats == true

        var matches: [TransactionMatch] = []
        for t in transactions where !linked.contains(t.id) {
            let days = abs(daysBetween(t.date, expense.date))
            guard days <= windowDays else { continue }
            guard let score = matchScore(amount: nsDouble(t.amount), full: full, myPaid: myPaid, days: days,
                                         txnTokens: tokens(t.details), expenseTokens: expenseTokens,
                                         recurring: recurring) else { continue }
            matches.append(TransactionMatch(transaction: t, score: score))
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Symmetric ranking for the reverse flow ("link an existing expense to this transaction"): unlinked,
    /// non-neutral expenses scored against a transaction by the same amount/date/name signals.
    static func expenseCandidates(for transaction: Transaction, expenses: [Expense], me: String?,
                                  limit: Int = 8, windowDays: Int = 21) -> [Expense] {
        let amount = nsDouble(transaction.amount)
        let txnTokens = tokens(transaction.details)
        var scored: [(Expense, Double)] = []
        for e in expenses where e.transactionId == nil {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }  // settle-up/transfer
            let days = abs(daysBetween(transaction.date, e.date))
            guard days <= windowDays else { continue }
            let myPaid = me.flatMap { id in e.splits.first { $0.userIdentifier == id }?.paidShare }
                .map(nsDouble)
            guard let score = matchScore(amount: amount, full: nsDouble(e.amount), myPaid: myPaid, days: days,
                                         txnTokens: txnTokens, expenseTokens: tokens(e.details),
                                         recurring: e.repeats == true) else { continue }
            scored.append((e, score))
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    // MARK: Scoring

    /// The shared exponential match score in 0...1 (nil if the amount pre-gate rejects it). `full`/`myPaid` are
    /// the two amount targets (the full bill or the caller's paid share); `days` = |date diff|. Recurrence
    /// picks the gentler decay rates + adds a small bonus.
    private static func matchScore(amount: Double, full: Double, myPaid: Double?, days: Int,
                                   txnTokens: Set<String>, expenseTokens: Set<String>,
                                   recurring: Bool) -> Double? {
        let kAmount = recurring ? kAmountRecurring : kAmountStrict
        let kDate = recurring ? kDateRecurring : kDateStrict
        // Best of (matches the full bill) / (matches your paid share).
        let relAmount = min(relDiff(amount, full), myPaid.map { relDiff(amount, $0) } ?? .infinity)
        let amountScore = exp(-kAmount * relAmount)
        guard amountScore >= minAmountScore else { return nil }  // amounts must be close to be the same bill
        let dateScore = exp(-kDate * Double(days))
        let nameScore = overlap(txnTokens, expenseTokens)
        var score = wAmount * amountScore + wDate * dateScore + wName * nameScore
        if recurring { score = min(1, score + recurringBonus) }
        return score
    }

    /// Relative difference |a−b|/b (∞ when b ≤ 0), so 0 = exact and the amount penalty scales with bill size.
    private static func relDiff(_ a: Double, _ b: Double) -> Double {
        guard b > 0 else { return .infinity }
        return abs(a - b) / b
    }

    /// Overlap coefficient |A∩B| / min(|A|,|B|) over meaningful tokens (0 when either side is empty).
    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// Lowercased alphanumeric tokens of length ≥ 2, minus payment-noise stop words.
    static func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { $0.count >= 2 && !stopWords.contains($0) })
    }

    private static func daysBetween(_ a: Date, _ b: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: a),
                                        to: Calendar.current.startOfDay(for: b)).day ?? Int.max
    }

    private static func nsDouble(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
}
