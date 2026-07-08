import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Guided-generation result: the chosen category + whether a change from the current one is clearly warranted.
@available(iOS 26, *)
@Generable
struct Refinement {
    @Guide(description: "The single best category, chosen only from the allowed list.")
    var category: String
    @Guide(description: "True only if a category DIFFERENT from the current one is clearly more accurate.")
    var changeIsClear: Bool
}
#endif

/// Maps raw Plaid category labels to canonical categories using Apple's on-device Foundation Models
/// (Apple Intelligence). Nothing leaves the device; unavailable hardware/OS makes this a no-op and the
/// manual category picker remains the path.
enum CategoryMapper {
    /// Whether the on-device model is usable right now (capable device, model downloaded, AI enabled).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// One transaction to refine: its id, merchant description, the Plaid category label, the **current**
    /// canonical category (so the model can anchor on it and abstain unless a change is clearly better), and
    /// the user's optional free-text note (a personal annotation that disambiguates a vague merchant).
    struct Item: Sendable {
        let id: UUID
        let description: String
        let rawCategory: String?
        let current: String?
        let note: String?

        init(id: UUID, description: String, rawCategory: String?, current: String?, note: String? = nil) {
            self.id = id
            self.description = description
            self.rawCategory = rawCategory
            self.current = current
            self.note = note
        }
    }

    /// The refinement prompt for one item. Pure (no model call) so it's unit-testable. Injects the user's note
    /// when present so the model can disambiguate a vague merchant (e.g. "Apple" + note "Duolingo subscription").
    static func refinePrompt(_ item: Item, allowed: [String]) -> String {
        let hint = item.rawCategory.map { " (bank category: \($0))" } ?? ""
        let anchor = item.current.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedNote = item.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteLine = (trimmedNote?.isEmpty == false)
            ? "\nUser note (the buyer's own description of this purchase): \"\(trimmedNote!)\"."
            : ""
        return """
        Allowed categories: \(allowed.joined(separator: ", ")).
        Transaction: "\(item.description)"\(hint).\(noteLine)
        Current category: \(anchor ?? "Uncategorized").
        Pick the best category, and set changeIsClear to true only if a DIFFERENT category is clearly \
        more accurate than the current one.
        """
    }

    /// Refines transactions using the **merchant description** (plus the Plaid category as a hint), anchored on
    /// the **current** category: only returns a *different* category when the model is confident it's clearly
    /// more accurate - so an already-decent label (e.g. Amazon → "Shopping") isn't second-guessed. Returns
    /// {transactionId: canonical} only for those confident, changed placements.
    static func refine(_ items: [Item], allowed: [String] = CanonicalCategory.all) async -> [UUID: String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let instructions = """
            You categorize bank transactions into a fixed taxonomy from the merchant/description. Each \
            transaction already has a current category — keep it unless a DIFFERENT allowed category is clearly \
            more accurate. Choose only from the allowed list.
            """
            var result: [UUID: String] = [:]
            for item in items {
                let session = LanguageModelSession(instructions: instructions)
                // Anchored (a real current category) → abstain unless a different one is clearly better.
                // Unanchored (nil/empty current, e.g. a fresh receipt) → just classify and take a confident match.
                let anchor = item.current.flatMap { $0.isEmpty ? nil : $0 }
                let prompt = refinePrompt(item, allowed: allowed)
                guard let r = try? await session.respond(to: prompt, generating: Refinement.self).content,
                      let match = allowed.first(where: { $0.caseInsensitiveCompare(r.category) == .orderedSame })
                else { continue }
                if let anchor, !(r.changeIsClear && match.caseInsensitiveCompare(anchor) != .orderedSame) {
                    continue   // keep the current category - no confident, different improvement
                }
                result[item.id] = match
            }
            return result
        }
        #endif
        return [:]
    }

    /// Classifies each raw label into one canonical category. Skips anything the model can't confidently
    /// place in the allowed set. Returns {raw: canonical}.
    static func suggest(for rawLabels: [String], allowed: [String] = CanonicalCategory.all) async -> [String: String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let instructions = """
            You classify bank-transaction category labels into a fixed taxonomy. Reply with ONLY the \
            single best-matching category name from the allowed list — no punctuation, no explanation.
            """
            var result: [String: String] = [:]
            for raw in rawLabels {
                let session = LanguageModelSession(instructions: instructions)
                let prompt = """
                Allowed categories: \(allowed.joined(separator: ", ")).
                Label: "\(raw)".
                Best category:
                """
                guard let response = try? await session.respond(to: prompt) else { continue }
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = allowed.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    result[raw] = match
                }
            }
            return result
        }
        #endif
        return [:]
    }
}
