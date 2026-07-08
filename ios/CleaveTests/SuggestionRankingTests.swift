import XCTest
@testable import CleaveAPI

/// `SuggestionRanking` is pure (no DB), so these exercise the score ordering + cap directly.
final class SuggestionRankingTests: XCTestCase {
    private func make(_ id: String, _ kind: Suggestion.Kind, daysAgo: Double, match: Double? = nil,
                      coverage: Int = 1) -> Suggestion {
        Suggestion(id: id, kind: kind, title: id, subtitle: "", icon: "", acceptLabel: "",
                   transactionIds: Array(repeating: UUID(), count: coverage),
                   matchScore: match, sortDate: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    func testTypeOrderDominates() {
        // Same recency: Link/Split outrank Categorize outrank nudges outrank Subscription.
        let ranked = SuggestionRanking.ranked([
            make("sub", .subscription, daysAgo: 0),
            make("over", .overspend, daysAgo: 0),
            make("cat", .categorize, daysAgo: 0),
            make("link", .link, daysAgo: 0, match: 0.9),
            make("split", .recurringSplit, daysAgo: 0),
        ])
        let kinds = ranked.map(\.kind)
        XCTAssertTrue(kinds.first == .link || kinds.first == .recurringSplit)
        XCTAssertEqual(kinds.last, .subscription)
        XCTAssertLessThan(kinds.firstIndex(of: .categorize)!, kinds.firstIndex(of: .overspend)!)
        XCTAssertLessThan(kinds.firstIndex(of: .overspend)!, kinds.firstIndex(of: .subscription)!)
    }

    func testRecencyBreaksWithinType() {
        let ranked = SuggestionRanking.ranked([
            make("old", .link, daysAgo: 120, match: 0.9),
            make("new", .link, daysAgo: 0, match: 0.9),
        ])
        XCTAssertEqual(ranked.first?.id, "new")
    }

    func testFreshLowerTypeCanEdgeStaleHigherType() {
        // A brand-new categorize can outrank a months-old link (the recency-weighted blend).
        let ranked = SuggestionRanking.ranked([
            make("oldlink", .link, daysAgo: 400, match: 0.85),
            make("newcat", .categorize, daysAgo: 0, coverage: 10),
        ])
        XCTAssertEqual(ranked.first?.id, "newcat")
    }

    func testCapsAtMaxCards() {
        let many = (0..<60).map { make("c\($0)", .categorize, daysAgo: Double($0)) }
        XCTAssertEqual(SuggestionRanking.ranked(many).count, SuggestionRanking.maxCards)
    }
}
