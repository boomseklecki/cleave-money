import XCTest
import SwiftData
@testable import CleaveAPI

/// Cross-device sync of templates + decisions round-trips through the snapshot.
@MainActor
final class SuggestionSyncTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        let container = try CleaveStore.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SplitTemplate(merchantKey: "rent", groupId: UUID(), category: "Rent",
                                     sharesJSON: SplitTemplate.encode(["me": 0.5, "alex": 0.5]),
                                     source: "explicit", displayName: "Rent"))
        context.insert(SuggestionDecision(key: "sub:netflix", decision: "dismissed"))
        context.insert(SubscriptionRule(merchantKey: "claude", amount: 20, isSubscription: true,
                                        displayName: "Claude"))
        try context.save()

        let data = try JSONEncoder().encode(try SuggestionSync.snapshot(context))
        let decoded = try JSONDecoder().decode(SuggestionSnapshot.self, from: data)

        // Wipe, then restore from the decoded snapshot (simulates a new device).
        for t in try context.fetch(FetchDescriptor<SplitTemplate>()) { context.delete(t) }
        for d in try context.fetch(FetchDescriptor<SuggestionDecision>()) { context.delete(d) }
        for r in try context.fetch(FetchDescriptor<SubscriptionRule>()) { context.delete(r) }
        try context.save()
        try SuggestionSync.apply(decoded, context)

        let templates = try context.fetch(FetchDescriptor<SplitTemplate>())
        let decisions = try context.fetch(FetchDescriptor<SuggestionDecision>())
        let rules = try context.fetch(FetchDescriptor<SubscriptionRule>())
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.merchantKey, "rent")
        XCTAssertEqual(templates.first?.source, "explicit")
        XCTAssertEqual(templates.first?.shares["me"] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.key, "sub:netflix")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.merchantKey, "claude")
        XCTAssertEqual(rules.first?.amount, 20)
        XCTAssertEqual(rules.first?.isSubscription, true)
    }

    /// A legacy blob (no `rules` key) still decodes - `rules` is Optional so templates/decisions restore
    /// isn't broken by the added field.
    func testLegacyBlobDecodesWithoutRules() throws {
        let legacy = #"{"version":1,"templates":[],"decisions":[{"key":"sub:x","decision":"dismissed"}]}"#
        let snap = try JSONDecoder().decode(SuggestionSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(snap.rules)
        XCTAssertEqual(snap.decisions.count, 1)
    }
}
