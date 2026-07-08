import Foundation
import FoundationModels

/// The model's pick of the best candidate, by 1-based list position (0 = none convincing).
@Generable
struct TransactionMatchChoice {
    @Guide(description: "The number of the transaction that best matches the expense, or 0 if none fit")
    var bestIndex: Int
    @Guide(description: "A short reason, at most 8 words")
    var reason: String
}

/// Drives the "link a transaction" suggestions: a deterministic heuristic ranking
/// (`TransactionMatcher`), optionally re-ranked by Apple's on-device model to float the single best match
/// to the top with a one-line reason. Mirrors `ReceiptScanModel`: `@MainActor @Observable`, graceful when
/// Apple Intelligence is unavailable (the heuristic order stands).
@MainActor
@Observable
final class TransactionMatchModel {
    /// Ranked suggestions (heuristic, top possibly re-ordered by the model).
    var candidates: [TransactionMatch] = []
    var isRanking = false
    /// One-line rationale for the top suggestion when the model contributed it; empty otherwise.
    var topReason: String = ""
    /// True once the on-device model refined the order (drives the "sparkles" affordance).
    var usedAppleIntelligence = false

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func load(expense: Expense, transactions: [Transaction], expenses: [Expense], me: String?) async {
        isRanking = true
        defer { isRanking = false }
        let base = TransactionMatcher.transactionCandidates(for: expense, transactions: transactions,
                                                 expenses: expenses, me: me)
        candidates = base
        guard isAvailable, base.count > 1 else { return }
        await refine(expense: expense, base: base)
    }

    /// Asks the on-device model to pick the best of the top heuristic candidates and floats it first.
    private func refine(expense: Expense, base: [TransactionMatch]) async {
        let top = Array(base.prefix(5))
        let lines = top.enumerated().map { i, m in
            "\(i + 1). \(m.transaction.details) — "
                + m.transaction.amount.formatted(.currency(code: m.transaction.currency))
                + " on \(m.transaction.date.dateOnly())"
        }.joined(separator: "\n")
        let instructions = """
        You match a shared expense to the bank transaction that paid for it. Consider the description, the \
        amount (the bank often pays the full bill, not just one person's share), and the date. Pick the \
        single best transaction by its number, or 0 if none are a convincing match.
        """
        let prompt = """
        Expense: "\(expense.details)" — \
        \(expense.amount.formatted(.currency(code: expense.currency))) on \
        \(expense.date.dateOnly()).
        Transactions:
        \(lines)
        """
        let session = LanguageModelSession(instructions: instructions)
        guard let choice = try? await session.respond(
            to: prompt, generating: TransactionMatchChoice.self).content else { return }
        usedAppleIntelligence = true
        let idx = choice.bestIndex - 1
        guard top.indices.contains(idx) else { return }
        let best = top[idx]
        // Float the chosen candidate to the front (stable for the rest).
        candidates = [best] + base.filter { $0.id != best.id }
        topReason = choice.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
