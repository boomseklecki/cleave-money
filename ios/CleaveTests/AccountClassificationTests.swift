import XCTest
@testable import CleaveAPI

/// Account classification from the Plaid subtype string - drives which accounts count toward spend/cash-flow.
final class AccountClassificationTests: XCTestCase {
    func testClassifyLiability() {
        XCTAssertEqual(AccountKind.classify("credit card"), .liability)
        XCTAssertEqual(AccountKind.classify("mortgage"), .liability)
        XCTAssertEqual(AccountKind.classify("loan"), .liability)
        XCTAssertEqual(AccountKind.classify("CREDIT CARD"), .liability)   // case-insensitive
    }

    func testClassifyHoldings() {
        XCTAssertEqual(AccountKind.classify("investment"), .holdings)
        XCTAssertEqual(AccountKind.classify("401k"), .holdings)
        XCTAssertEqual(AccountKind.classify("roth ira"), .holdings)
    }

    func testClassifyDefaultsToCashFlow() {
        XCTAssertEqual(AccountKind.classify("checking"), .cashFlow)
        XCTAssertEqual(AccountKind.classify("savings"), .cashFlow)   // a deposit account, not "holdings"
        XCTAssertEqual(AccountKind.classify("something weird"), .cashFlow)
        XCTAssertEqual(AccountKind.classify(nil), .cashFlow)
        XCTAssertEqual(AccountKind.classify(""), .cashFlow)
    }

    func testCanonicalRoundTrip() {
        XCTAssertEqual(AccountKind.cashFlow.canonical, "cash_flow")
        XCTAssertEqual(AccountKind.liability.canonical, "liability")
        XCTAssertEqual(AccountKind.holdings.canonical, "savings")
        XCTAssertEqual(AccountKind(canonical: "cash_flow"), .cashFlow)
        XCTAssertEqual(AccountKind(canonical: "liability"), .liability)
        XCTAssertEqual(AccountKind(canonical: "savings"), .holdings)
        XCTAssertEqual(AccountKind(canonical: "holdings"), .holdings)   // legacy alias
        XCTAssertNil(AccountKind(canonical: "nonsense"))
    }
}
