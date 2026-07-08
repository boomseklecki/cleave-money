import XCTest
@testable import CleaveAPI

/// The on-device refinement prompt (pure string, no model call) injects the user's note as extra context so a
/// vague merchant can be disambiguated, and omits it when the note is absent/blank.
final class CategoryMapperTests: XCTestCase {
    private func item(note: String?) -> CategoryMapper.Item {
        CategoryMapper.Item(id: UUID(), description: "Apple", rawCategory: "GENERAL_MERCHANDISE",
                            current: "Shopping", note: note)
    }

    func testPromptIncludesNoteWhenPresent() {
        let prompt = CategoryMapper.refinePrompt(item(note: "Duolingo subscription"),
                                                 allowed: ["Learning", "Shopping"])
        XCTAssertTrue(prompt.contains("User note"))
        XCTAssertTrue(prompt.contains("Duolingo subscription"))
    }

    func testPromptOmitsNoteWhenNilOrBlank() {
        XCTAssertFalse(CategoryMapper.refinePrompt(item(note: nil), allowed: ["Shopping"]).contains("User note"))
        XCTAssertFalse(CategoryMapper.refinePrompt(item(note: "   "), allowed: ["Shopping"]).contains("User note"))
    }

    func testPromptCarriesDescriptionAnchorAndAllowed() {
        let prompt = CategoryMapper.refinePrompt(item(note: nil), allowed: ["Learning", "Shopping"])
        XCTAssertTrue(prompt.contains("\"Apple\""))
        XCTAssertTrue(prompt.contains("Learning, Shopping"))
        XCTAssertTrue(prompt.contains("Current category: Shopping"))
    }
}
