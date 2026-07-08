import Foundation

/// Auto-derives split templates from history so the review queue can suggest "split like last time."
/// A merchant counts when it has ≥`minOccurrences` **shared, transaction-linked** expenses (the recurring
/// real charges) in a single group; the template captures the averaged owed-split fractions.
enum SplitTemplateLearning {
    static func derive(expenses: [Expense], minOccurrences: Int = 2) -> [SplitTemplate] {
        var byKey: [String: [Expense]] = [:]
        for e in expenses where e.transactionId != nil {
            guard e.splits.filter({ $0.owedShare > 0 }).count >= 2 else { continue }  // actually shared
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }
            let key = MerchantText.key(e.details)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(e)
        }

        var templates: [SplitTemplate] = []
        for (key, group) in byKey where group.count >= minOccurrences {
            // Consistency: the same group across occurrences (otherwise the "template" is ambiguous).
            let groupIds = Set(group.map(\.groupId))
            guard groupIds.count == 1, let groupId = groupIds.first else { continue }

            var fractionSums: [String: Double] = [:]
            for e in group {
                let total = e.splits.reduce(Decimal(0)) { $0 + max($1.owedShare, 0) }
                guard total > 0 else { continue }
                for s in e.splits where s.owedShare > 0 {
                    fractionSums[s.userIdentifier, default: 0] +=
                        NSDecimalNumber(decimal: s.owedShare / total).doubleValue
                }
            }
            guard !fractionSums.isEmpty else { continue }
            let n = Double(group.count)
            let fractions = fractionSums.mapValues { $0 / n }
            let latest = group.max { $0.date < $1.date }
            templates.append(SplitTemplate(
                merchantKey: key, groupId: groupId, category: latest?.category,
                sharesJSON: SplitTemplate.encode(fractions), source: "auto",
                displayName: latest?.details ?? key))
        }
        return templates
    }
}
