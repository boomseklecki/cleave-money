import XCTest
@testable import CleaveAPI

/// Verifies the transport→SwiftData mapping chokepoint: Decimal precision, enum/date conversion,
/// nested splits/items/receipts, optional/null fields, and error handling. This is the Phase 1
/// green-light gate.
final class MappingTests: XCTestCase {
    private let uuidA = "11111111-1111-1111-1111-111111111111"
    private let uuidB = "22222222-2222-2222-2222-222222222222"
    private let uuidC = "33333333-3333-3333-3333-333333333333"
    private let epoch = Date(timeIntervalSince1970: 0)

    // MARK: Group

    func testGroupMapping_selfHosted_withNullableFieldsNil() throws {
        let response = Components.Schemas.GroupResponse(
            id: uuidA,
            name: "Household",
            backend_type: .self_hosted,
            hidden: false,
            created_at: epoch,
            updated_at: epoch
        )
        let group = try Mapping.group(response)
        XCTAssertEqual(group.id, UUID(uuidString: uuidA))
        XCTAssertEqual(group.name, "Household")
        XCTAssertEqual(group.backendType, .selfHosted)
        XCTAssertNil(group.splitwiseGroupId)
        XCTAssertNil(group.supersededAt)
        XCTAssertFalse(group.hidden)
    }

    func testGroupMapping_splitwise_withNullableFieldsPresent() throws {
        let archived = Date(timeIntervalSince1970: 1_700_000_000)
        let response = Components.Schemas.GroupResponse(
            id: uuidB,
            name: "Trip",
            backend_type: .splitwise,
            splitwise_group_id: "sw-42",
            hidden: true,
            superseded_at: archived,
            created_at: epoch,
            updated_at: epoch
        )
        let group = try Mapping.group(response)
        XCTAssertEqual(group.backendType, .splitwise)
        XCTAssertEqual(group.splitwiseGroupId, "sw-42")
        XCTAssertEqual(group.supersededAt, archived)
        XCTAssertTrue(group.hidden)
    }

    // MARK: Expense (nested) + Decimal precision + date-only

    func testExpenseMapping_withSplitsItemsReceipts() throws {
        let response = Components.Schemas.ExpenseResponse(
            id: uuidA,
            group_id: uuidB,
            transaction_id: uuidC,
            description: "Groceries",
            amount: "42.50",
            currency: "USD",
            date: "2026-06-18",
            category: "food",
            created_at: epoch,
            updated_at: epoch,
            splits: [
                .init(id: uuidA, user_identifier: "alice", paid_share: "42.50", owed_share: "21.25"),
                .init(id: uuidB, user_identifier: "bob", paid_share: "0.00", owed_share: "21.25")
            ],
            items: [
                .init(id: uuidC, name: "Milk", quantity: "2", price: "3.49", category: "dairy",
                      created_at: epoch, updated_at: epoch)
            ],
            receipts: [
                .init(id: uuidA, expense_id: uuidA, bucket: "receipts", object_key: "k/1.jpg",
                      content_type: "image/jpeg", created_at: epoch)
            ]
        )
        let expense = try Mapping.expense(response)
        XCTAssertEqual(expense.id, UUID(uuidString: uuidA))
        XCTAssertEqual(expense.groupId, UUID(uuidString: uuidB))
        XCTAssertEqual(expense.transactionId, UUID(uuidString: uuidC))
        XCTAssertEqual(expense.details, "Groceries")
        XCTAssertEqual(expense.amount, Decimal(string: "42.50"))
        XCTAssertEqual(expense.date, Mapping.dateOnlyFormatter.date(from: "2026-06-18"))
        XCTAssertEqual(expense.category, "food")

        XCTAssertEqual(expense.splits.count, 2)
        let owed = expense.splits.reduce(Decimal(0)) { $0 + $1.owedShare }
        XCTAssertEqual(owed, Decimal(string: "42.50"))

        XCTAssertEqual(expense.items.count, 1)
        XCTAssertEqual(expense.items.first?.price, Decimal(string: "3.49"))
        XCTAssertEqual(expense.items.first?.quantity, Decimal(2))

        XCTAssertEqual(expense.receipts.count, 1)
        XCTAssertEqual(expense.receipts.first?.objectKey, "k/1.jpg")
        XCTAssertEqual(expense.receipts.first?.contentType, "image/jpeg")
    }

    func testExpenseMapping_emptyAndNullableCollections() throws {
        let response = Components.Schemas.ExpenseResponse(
            id: uuidA,
            group_id: uuidB,
            description: "Manual",
            amount: "0.00",
            currency: "USD",
            date: "2026-01-01",
            created_at: epoch,
            updated_at: epoch
        )
        let expense = try Mapping.expense(response)
        XCTAssertNil(expense.transactionId)
        XCTAssertNil(expense.splitwiseExpenseId)
        XCTAssertNil(expense.category)
        XCTAssertTrue(expense.splits.isEmpty)
        XCTAssertTrue(expense.items.isEmpty)
        XCTAssertTrue(expense.receipts.isEmpty)
    }

    // MARK: Transaction + Account

    func testTransactionMapping_plaidSource() throws {
        let response = Components.Schemas.TransactionResponse(
            id: uuidA,
            account_id: uuidB,
            plaid_transaction_id: "plaid-1",
            source: .plaid,
            description: "Coffee",
            amount: "5.75",
            currency: "USD",
            date: "2026-06-17",
            category: "coffee",
            pending: true,
            created_at: epoch,
            updated_at: epoch
        )
        let txn = try Mapping.transaction(response)
        XCTAssertEqual(txn.accountId, UUID(uuidString: uuidB))
        XCTAssertEqual(txn.plaidTransactionId, "plaid-1")
        XCTAssertEqual(txn.source, .plaid)
        XCTAssertEqual(txn.details, "Coffee")
        XCTAssertEqual(txn.amount, Decimal(string: "5.75"))
        XCTAssertTrue(txn.pending)
    }

    func testAccountMapping_decimalBalanceAndType() throws {
        let response = Components.Schemas.AccountResponse(
            id: uuidA,
            name: "Checking",
            _type: "depository",
            plaid_account_id: "acct-1",
            balance: "1234.56",
            currency: "USD",
            share_level: "private",
            created_at: epoch,
            updated_at: epoch
        )
        let account = try Mapping.account(response)
        XCTAssertEqual(account.name, "Checking")
        XCTAssertEqual(account.type, "depository")
        XCTAssertEqual(account.balance, Decimal(string: "1234.56"))
        XCTAssertEqual(account.shareLevel, "private")
        XCTAssertNil(account.plaidItemId)
    }

    // MARK: Error handling

    func testInvalidDecimalThrows() {
        XCTAssertThrowsError(try Mapping.decimal("not-a-number", field: "x")) { error in
            XCTAssertEqual(error as? MappingError, .invalidDecimal("not-a-number", field: "x"))
        }
    }

    func testInvalidUUIDThrows() {
        XCTAssertThrowsError(try Mapping.uuid("nope", field: "x")) { error in
            XCTAssertEqual(error as? MappingError, .invalidUUID("nope", field: "x"))
        }
    }

    func testInvalidDateThrows() {
        XCTAssertThrowsError(try Mapping.dateOnly("2026/06/18", field: "x")) { error in
            XCTAssertEqual(error as? MappingError, .invalidDate("2026/06/18", field: "x"))
        }
    }

    func testDecimalPrecisionPreserved() throws {
        XCTAssertEqual(try Mapping.decimal("1000000.99", field: "x"), Decimal(string: "1000000.99"))
        XCTAssertEqual(try Mapping.decimal("0.01", field: "x"), Decimal(string: "0.01"))
    }
}
