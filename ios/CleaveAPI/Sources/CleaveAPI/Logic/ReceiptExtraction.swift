import Foundation
import FoundationModels

/// The structured shape the on-device model fills in from receipt OCR text.
@Generable
struct ReceiptExtraction {
    @Guide(description: "The merchant or store name")
    var merchant: String

    @Guide(description: "The purchase date as YYYY-MM-DD")
    var date: String

    @Guide(description: "The grand total amount as a number, e.g. 42.50")
    var total: Double

    @Guide(description: "The purchased line items")
    var items: [ExtractedItem]
}

@Generable
struct ExtractedItem {
    @Guide(description: "Item name")
    var name: String

    @Guide(description: "Quantity (use 1 if unspecified)")
    var quantity: Double

    @Guide(description: "Line price as a number")
    var price: Double

    @Guide(description: "A category for the item if identifiable")
    var category: String?
}
