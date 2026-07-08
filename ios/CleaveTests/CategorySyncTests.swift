import XCTest
import SwiftData
@testable import CleaveAPI

/// The category taxonomy + raw→canonical map round-trip through the local snapshot/apply path (the same
/// `apply` the relational `GET /categories` restore now drives). Built-ins are forward-filled on apply.
@MainActor
final class CategorySyncTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        let container = try CleaveStore.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SpendCategory(id: UUID(), name: "Surf", builtin: false, position: 42, icon: "water.waves"))
        context.insert(CategoryMap(id: UUID(), rawCategory: "GENERAL_SERVICES", canonicalCategory: "Surf",
                                   source: "ondevice", createdAt: Date(), updatedAt: Date()))
        try context.save()

        let data = try JSONEncoder().encode(try CategorySync.snapshot(context))
        let decoded = try JSONDecoder().decode(CategorySnapshot.self, from: data)

        // Wipe, then restore from the decoded snapshot (simulates a new device pulling from the server).
        for c in try context.fetch(FetchDescriptor<SpendCategory>()) { context.delete(c) }
        for m in try context.fetch(FetchDescriptor<CategoryMap>()) { context.delete(m) }
        try context.save()
        try CategorySync.apply(decoded, context)

        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        XCTAssertEqual(maps.count, 1)
        XCTAssertEqual(maps.first?.rawCategory, "GENERAL_SERVICES")
        XCTAssertEqual(maps.first?.canonicalCategory, "Surf")
        XCTAssertEqual(maps.first?.source, "ondevice")

        // The custom category survived...
        let cats = try context.fetch(FetchDescriptor<SpendCategory>())
        XCTAssertTrue(cats.contains { $0.name == "Surf" && $0.icon == "water.waves" })
        // ...and the built-ins were forward-filled (apply calls CategorySeed.ensureBuiltins).
        XCTAssertTrue(cats.contains { $0.name == "Dining" })
    }
}
