import SwiftUI

/// Reusable totals for a list-section **footer** - they float in the open space below a group of rows (the
/// pattern used on the category-detail and accounts screens) instead of sitting in their own section. Compose
/// one or more metrics: a total amount, a count, an average. Examples:
///
///     TotalsFooter(metrics: [.total(sum, code: "USD")])                          // one total
///     TotalsFooter(metrics: [.count(n, label: "Transactions"),
///                            .total(sum, code: code), .average(avg, code: code)]) // count + total + average
struct TotalsFooter: View {
    let metrics: [Metric]

    struct Metric: Identifiable {
        let label: String
        let value: String
        var id: String { label }

        /// A currency total.
        static func total(_ amount: Decimal, code: String, label: String = "Total") -> Metric {
            Metric(label: label, value: amount.currency(code))
        }
        /// A whole-number count.
        static func count(_ n: Int, label: String) -> Metric {
            Metric(label: label, value: n.formatted())
        }
        /// A currency average.
        static func average(_ amount: Decimal, code: String, label: String = "Average") -> Metric {
            Metric(label: label, value: amount.currency(code))
        }
        /// A pre-formatted value (e.g. a signed/net currency), for callers with their own formatting.
        static func custom(_ label: String, _ value: String) -> Metric {
            Metric(label: label, value: value)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(metrics) { metric in
                HStack {
                    Text(metric.label)
                    Spacer()
                    Text(metric.value).monospacedDigit()
                }
            }
        }
        .font(.subheadline).fontWeight(.medium)
    }
}
