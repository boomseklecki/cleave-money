import XCTest
import SwiftData
@testable import CleaveAPI

final class GoalsAnalyticsTests: XCTestCase {
    private func account(type: String?, spending: Bool? = nil, cash: Bool? = nil,
                         balance: Decimal = 0) -> Account {
        Account(id: UUID(), name: "Acct", type: type, balance: balance, currency: "USD",
                includeInSpending: spending, includeInCashFlow: cash,
                createdAt: Date(), updatedAt: Date())
    }

    private func txn(_ amount: Decimal, category: String?, account: Account,
                     source: TransactionSource = .plaid, date: Date = Date()) -> Transaction {
        Transaction(id: UUID(), accountId: account.id, source: source, details: "t",
                    amount: amount, currency: "USD", date: date, category: category,
                    createdAt: Date(), updatedAt: Date())
    }

    /// An expense with a single split for `me` owing `owed`, optionally linked to a transaction.
    private func expense(_ amount: Decimal, category: String?, me: String = "me", owed: Decimal,
                         transactionId: UUID? = nil, splitwiseId: String? = nil,
                         date: Date = Date(), details: String = "e") -> Expense {
        let split = Split(id: UUID(), userIdentifier: me, paidShare: amount, owedShare: owed)
        return Expense(id: UUID(), groupId: UUID(), transactionId: transactionId,
                       splitwiseExpenseId: splitwiseId, details: details,
                       amount: amount, currency: "USD", date: date, category: category,
                       createdAt: Date(), updatedAt: Date(), splits: [split])
    }

    // MARK: CategoryMapping

    func testEffectiveCategoryPrecedence() {
        // Override wins over the built-in Plaid map.
        let map = [CategoryMap(id: UUID(), rawCategory: "FOOD_AND_DRINK_GROCERIES",
                              canonicalCategory: "Household", source: "manual",
                              createdAt: Date(), updatedAt: Date())]
        let lookup = CategoryMapping.lookup(map)
        let checking = account(type: "checking")
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "FOOD_AND_DRINK_GROCERIES", account: checking), lookup: lookup), "Household")
        // No override: the built-in Plaid map resolves a detailed label.
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", account: checking), lookup: [:]),
            "Personal Care")
        // Unrecognized label falls through to itself; nil category stays nil.
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "Groceries", account: checking), lookup: [:]), "Groceries")
        XCTAssertNil(CategoryMapping.effectiveCategory(
            for: txn(5, category: nil, account: checking), lookup: [:]))
    }

    func testRefinementBeatsBuiltinButNotMapOrOverride() {
        let checking = account(type: "checking")
        // A (confident) AI refinement now outranks even a confident built-in Plaid mapping - it's only ever
        // written when the model was clearly more accurate than the current category.
        let groceries = txn(20, category: "FOOD_AND_DRINK_GROCERIES", account: checking)
        groceries.refinedCategory = "Dining"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: groceries, lookup: [:]), "Dining")
        // A vague "Other" row uses the refinement when present.
        let vague = txn(20, category: "GENERAL_SERVICES_OTHER", account: checking)
        XCTAssertTrue(CategoryMapping.needsRefinement(vague, lookup: [:]))
        vague.refinedCategory = "Subscriptions"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: [:]), "Subscriptions")
        // A manual override still beats a refinement.
        let lookup = ["GENERAL_SERVICES_OTHER": "Fees"]
        XCTAssertFalse(CategoryMapping.needsRefinement(vague, lookup: lookup))
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: lookup), "Fees")
    }

    func testPerTransactionOverrideWinsAndStopsRefinement() {
        let checking = account(type: "checking")
        // A label map AND a confident built-in would both apply, but the per-transaction override wins.
        let lookup = ["FOOD_AND_DRINK_GROCERIES": "Household"]
        let t = txn(20, category: "FOOD_AND_DRINK_GROCERIES", account: checking)
        t.categoryOverride = "Dining"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: t, lookup: lookup), "Dining")
        // An override on a vague row removes it from the refinement candidates.
        let vague = txn(20, category: "GENERAL_SERVICES_OTHER", account: checking)
        XCTAssertTrue(CategoryMapping.needsRefinement(vague, lookup: [:]))
        vague.categoryOverride = "Subscriptions"
        XCTAssertFalse(CategoryMapping.needsRefinement(vague, lookup: [:]))
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: [:]), "Subscriptions")
        // An override applies even when the raw category is empty (e.g. a manual transaction).
        let manual = txn(20, category: nil, account: checking, source: .manual)
        manual.categoryOverride = "Pets"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: manual, lookup: [:]), "Pets")
    }

    func testPlaidCategoryMapping() {
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_GROCERIES"), "Groceries")
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_FAST_FOOD"), "Dining")  // primary default
        XCTAssertEqual(PlaidCategory.canonical("TRANSPORTATION_GAS"), "Fuel")
        XCTAssertEqual(PlaidCategory.canonical("TRANSPORTATION_PUBLIC_TRANSIT"), "Transport")
        XCTAssertEqual(PlaidCategory.canonical("INCOME_WAGES"), "Income")
        XCTAssertEqual(PlaidCategory.canonical("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"), "Transfer")
        XCTAssertEqual(PlaidCategory.canonical("LOAN_PAYMENTS_MORTGAGE_PAYMENT"), "Mortgage")
        XCTAssertNil(PlaidCategory.canonical("Some Random Merchant"))
        XCTAssertEqual(PlaidCategory.humanized("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS"),
                       "Personal Care Gyms And Fitness Centers")
    }

    // MARK: Account inclusion defaults + overrides

    func testInclusionDefaultsByKind() {
        XCTAssertTrue(account(type: "checking").countsInSpending)
        XCTAssertTrue(account(type: "checking").countsInCashFlow)
        XCTAssertTrue(account(type: "credit card").countsInSpending)   // credit spend counts
        XCTAssertFalse(account(type: "credit card").countsInCashFlow)  // but not in net income
        XCTAssertFalse(account(type: "investment").countsInSpending)   // holdings excluded
        XCTAssertFalse(account(type: "investment").countsInCashFlow)
        // Override wins over the default.
        XCTAssertTrue(account(type: "investment", cash: true).countsInCashFlow)
        XCTAssertFalse(account(type: "checking", spending: false).countsInSpending)
    }

    // MARK: SpendingAnalytics

    func testByCategoryExcludesTransfersIncomeAndNonSpendingAccounts() {
        let checking = account(type: "checking")
        let card = account(type: "credit card")
        let brokerage = account(type: "investment")
        let txns = [
            txn(20, category: "Dining", account: checking),
            txn(30, category: "Groceries", account: card),     // credit spend counts
            txn(-100, category: "Income", account: checking),  // inflow, not spend
            txn(50, category: "Transfer", account: checking),  // internal move, excluded
            txn(40, category: "Shopping", account: brokerage), // holdings, excluded
        ]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking, card, brokerage], lookup: [:])
        XCTAssertEqual(result.map(\.category), ["Groceries", "Dining"])  // desc by total
        XCTAssertEqual(result.first?.total, 30)
    }

    func testMonthlyNetIncomeCashFlowOnly() {
        let checking = account(type: "checking")
        let card = account(type: "credit card")
        let txns = [
            txn(-2000, category: "Income", account: checking),  // paycheck in
            txn(300, category: "Groceries", account: checking), // spend out
            txn(500, category: "Transfer", account: checking),  // excluded
            txn(150, category: "Dining", account: card),        // liability: not in cash flow
        ]
        let series = SpendingAnalytics.monthlyNetIncome(transactions: txns,
                                                        accounts: [checking, card], lookup: [:],
                                                        months: 1)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.value, 1700)  // 2000 in − 300 out
    }

    func testMonthlySpendingZeroFillsRange() {
        let checking = account(type: "checking")
        let series = SpendingAnalytics.monthlySpending(
            transactions: [txn(25, category: "Dining", account: checking)],
            accounts: [checking], lookup: [:], months: 3)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.last?.value, 25)   // current month
        XCTAssertEqual(series.first?.value, 0)   // two months ago, zero-filled
    }

    // MARK: Expenses↔transactions merge

    func testUnlinkedExpenseCountsAtOwedShare() {
        let checking = account(type: "checking")
        let txns = [txn(30, category: "Dining", account: checking)]
        // A $60 dinner split - my share is $20 - with no linked transaction.
        let exps = [expense(60, category: "Dining", owed: 20)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.first?.category, "Dining")
        XCTAssertEqual(result.first?.total, 50)  // 30 transaction + 20 owed share
        // Monthly spending picks it up too.
        let series = SpendingAnalytics.monthlySpending(transactions: txns, accounts: [checking],
                                                       lookup: [:], months: 1, expenses: exps, me: "me")
        XCTAssertEqual(series.first?.value, 50)
    }

    func testLinkedPairCountsYourShareNotGross() {
        let checking = account(type: "checking")
        // A $60 dinner paid in full from the bank, linked to the expense where my share is $20. The pair
        // de-dupes to my share (20), dropping the gross transaction - not 60, and not 80.
        let t = txn(60, category: "Dining", account: checking)
        let exps = [expense(60, category: "Dining", owed: 20, transactionId: t.id)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [t],
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.first?.category, "Dining")
        XCTAssertEqual(result.first?.total, 20)  // your share only; the $60 transaction is suppressed

        // The mortgage case: $2000 bank payment linked to a $1000 Splitwise half → category shows $1000.
        let pay = txn(2000, category: "Mortgage", account: checking)
        let mortgage = [expense(2000, category: "Mortgage", owed: 1000, transactionId: pay.id)]
        let m = SpendingAnalytics.byCategory(in: Date(), transactions: [pay], accounts: [checking],
                                             lookup: [:], expenses: mortgage, me: "me")
        XCTAssertEqual(m.first?.total, 1000)
    }

    func testUnsharedLinkedExpenseNetsToGross() {
        let checking = account(type: "checking")
        // A solo $60 expense (you owe the whole thing) linked to its $60 transaction → still $60, once.
        let t = txn(60, category: "Dining", account: checking)
        let exps = [expense(60, category: "Dining", owed: 60, transactionId: t.id)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [t],
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.first?.total, 60)
    }

    func testExcludedAndZeroShareExpensesIgnored() {
        let checking = account(type: "checking")
        let exps = [
            expense(100, category: "Settle-up", owed: 50),  // internal, excluded
            expense(100, category: "Income", owed: 50),     // not spend, excluded
            expense(40, category: "Dining", owed: 0),        // you owe nothing → skip
            expense(40, category: "Dining", me: "other", owed: 40),  // no split for me → skip
        ]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [],
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertTrue(result.isEmpty)
    }

    func testIncomeAndReimbursementCountAsInflow() {
        let checking = account(type: "checking")
        // Income item: your owed share is an income inflow, not spend.
        let income = expense(100, category: "Income", owed: 40, splitwiseId: "i1")
        XCTAssertTrue(SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                   lookup: [:], expenses: [income], me: "me").isEmpty)
        XCTAssertEqual(SpendingAnalytics.monthlyNetIncome(transactions: [], accounts: [checking],
                          lookup: [:], months: 1, expenses: [income], me: "me").first?.value, 40)
        // Reimbursement: your "gets back" (paidShare) is an inflow, not spend.
        let reimb = expense(50, category: "Reimbursement", owed: 0)  // helper sets paidShare = amount
        XCTAssertTrue(SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                   lookup: [:], expenses: [reimb], me: "me").isEmpty)
        XCTAssertEqual(SpendingAnalytics.monthlyNetIncome(transactions: [], accounts: [checking],
                          lookup: [:], months: 1, expenses: [reimb], me: "me").first?.value, 50)
    }

    func testSettleUpAndTransferExpensesAreNeutral() {
        let checking = account(type: "checking")
        let exps = [expense(50, category: "Settle-up", owed: 50, splitwiseId: "s1"),
                    expense(50, category: "Transfer", owed: 50)]
        XCTAssertTrue(SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                   lookup: [:], expenses: exps, me: "me").isEmpty)
        // Neither inflow nor outflow.
        XCTAssertEqual(SpendingAnalytics.monthlyNetIncome(transactions: [], accounts: [checking],
                          lookup: [:], months: 1, expenses: exps, me: "me").first?.value, 0)
    }

    func testUnlinkedExpenseReducesNetIncome() {
        let checking = account(type: "checking")
        let txns = [txn(-2000, category: "Income", account: checking)]  // paycheck in
        let exps = [expense(60, category: "Dining", owed: 20)]          // cash dinner share out
        let series = SpendingAnalytics.monthlyNetIncome(transactions: txns, accounts: [checking],
                                                        lookup: [:], months: 1, expenses: exps, me: "me")
        XCTAssertEqual(series.first?.value, 1980)  // 2000 in − 20 owed share
    }

    func testSplitwiseCategoryMapping() {
        XCTAssertEqual(SplitwiseCategory.canonical("Dining out"), "Dining")
        XCTAssertEqual(SplitwiseCategory.canonical("Gas/fuel"), "Fuel")
        XCTAssertEqual(SplitwiseCategory.canonical("Electricity"), "Utilities")
        XCTAssertEqual(SplitwiseCategory.canonical("Medical expenses"), "Health")
        XCTAssertNil(SplitwiseCategory.canonical("Not A Splitwise Category"))
        // Routed through CategoryMapping.canonical (after the Plaid map).
        XCTAssertEqual(CategoryMapping.canonical("Dining out", lookup: [:]), "Dining")
        // A manual override still wins over the Splitwise map.
        XCTAssertEqual(CategoryMapping.canonical("Dining out", lookup: ["Dining out": "Entertainment"]),
                       "Entertainment")
    }

    func testSplitwiseExpenseFoldsIntoCanonicalBucket() {
        let checking = account(type: "checking")
        // A Plaid "Dining" transaction and a Splitwise "Dining out" expense should share one slice.
        let txns = [txn(30, category: "Dining", account: checking)]
        let exps = [expense(60, category: "Dining out", owed: 20)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, "Dining")
        XCTAssertEqual(result.first?.total, 50)  // not fragmented into a separate "Dining out" slice
    }

    func testCategoryDependentsReverseMapping() {
        let checking = account(type: "checking")
        // A Plaid label that resolves to Dining via the built-in primary map (no override row),
        let txns = [
            txn(5, category: "FOOD_AND_DRINK_COFFEE", account: checking),
            txn(5, category: "FOOD_AND_DRINK_GROCERIES", account: checking),  // -> Groceries
        ]
        // a Splitwise name that resolves to Dining via the deterministic Splitwise map,
        let exps = [expense(10, category: "Dining out", owed: 10, splitwiseId: "sw1"),
                    expense(10, category: "Settle-up", owed: 10, splitwiseId: "sw2")]  // excluded
        let grouped = CategoryDependents.grouped(transactions: txns, expenses: exps, categoryMaps: [])
        let dining = (grouped["Dining"] ?? []).map(\.raw).sorted()
        XCTAssertEqual(dining, ["Dining out", "FOOD_AND_DRINK_COFFEE"])  // built-in links, not just overrides
        XCTAssertEqual(grouped["Groceries"]?.map(\.raw), ["FOOD_AND_DRINK_GROCERIES"])
        XCTAssertNil(grouped["Settle-up"])  // settle-up excluded

        // An override re-points a label to a different canonical, moving it in the reverse map.
        let maps = [CategoryMap(id: UUID(), rawCategory: "FOOD_AND_DRINK_COFFEE",
                                canonicalCategory: "Household", source: "manual",
                                createdAt: Date(), updatedAt: Date())]
        let grouped2 = CategoryDependents.grouped(transactions: txns, expenses: exps, categoryMaps: maps)
        XCTAssertEqual(grouped2["Dining"]?.map(\.raw), ["Dining out"])
        XCTAssertEqual(grouped2["Household"]?.map(\.raw), ["FOOD_AND_DRINK_COFFEE"])
    }

    func testItemizedAttribution() {
        let checking = account(type: "checking")
        let me = "me"
        // $100 expense (category Shopping). Items: Groceries $40 + Personal Care $30 assigned to me,
        // Snacks $20 unassigned, $10 non-item remainder (tax). Two participants; the $30 shared pool
        // (snacks + tax) splits equally → my owed = 70 + 15 = 85.
        let exp = Expense(
            id: UUID(), groupId: UUID(), details: "Target run", amount: 100, currency: "USD",
            date: Date(), category: "Shopping", createdAt: Date(), updatedAt: Date(),
            splits: [
                Split(id: UUID(), userIdentifier: me, paidShare: 100, owedShare: 85),
                Split(id: UUID(), userIdentifier: "friend", paidShare: 0, owedShare: 15),
            ],
            items: [
                ExpenseItem(id: UUID(), name: "Milk", quantity: 1, price: 40, category: "Groceries", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Soap", quantity: 1, price: 30, category: "Personal Care", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Chips", quantity: 1, price: 20, category: "Snacks", ownerIdentifier: nil),
            ])
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                  lookup: [:], expenses: [exp], me: me)
        let byCat = Dictionary(result.map { ($0.category, $0.total) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byCat["Groceries"], 40)        // assigned to me, full price
        XCTAssertEqual(byCat["Personal Care"], 30)    // assigned to me, full price
        XCTAssertEqual(byCat["Snacks"], 10)           // my 15 pool share × 20/30
        XCTAssertEqual(byCat["Shopping"], 5)          // remainder → expense category, 15 × 10/30
        XCTAssertEqual(result.reduce(Decimal(0)) { $0 + $1.total }, 85)  // sums to my owed share
    }

    func testItemizedSplitwiseIgnoresOwners() {
        let checking = account(type: "checking")
        let me = "me"
        // Same itemized layout, but a Splitwise expense: owners are ignored → my owed share ($85) is
        // spread proportionally across all item categories by price (90 of items + 10 remainder = 100).
        let exp = Expense(
            id: UUID(), groupId: UUID(), splitwiseExpenseId: "sw-1", details: "Target run",
            amount: 100, currency: "USD", date: Date(), category: "Shopping",
            createdAt: Date(), updatedAt: Date(),
            splits: [
                Split(id: UUID(), userIdentifier: me, paidShare: 100, owedShare: 85),
                Split(id: UUID(), userIdentifier: "friend", paidShare: 0, owedShare: 15),
            ],
            items: [
                ExpenseItem(id: UUID(), name: "Milk", quantity: 1, price: 40, category: "Groceries", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Soap", quantity: 1, price: 30, category: "Personal Care", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Chips", quantity: 1, price: 20, category: "Snacks", ownerIdentifier: nil),
            ])
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                  lookup: [:], expenses: [exp], me: me)
        let byCat = Dictionary(result.map { ($0.category, $0.total) }, uniquingKeysWith: { a, _ in a })
        // Proportional: 85 × price/100. Groceries 34, Personal Care 25.5, Snacks 17, Shopping (rem) 8.5.
        XCTAssertEqual(byCat["Groceries"], Decimal(string: "34"))
        XCTAssertEqual(byCat["Personal Care"], Decimal(string: "25.5"))
        XCTAssertEqual(byCat["Snacks"], Decimal(string: "17"))
        XCTAssertEqual(byCat["Shopping"], Decimal(string: "8.5"))
        XCTAssertEqual(result.reduce(Decimal(0)) { $0 + $1.total }, 85)
    }

    func testManualTransactionsCount() {
        let checking = account(type: "checking")
        let holdings = account(type: "investment")  // excluded from spend + cash flow
        // Cash manual transaction (no account) counts toward spend + reduces net income.
        let cash = txn(25, category: "Dining", account: checking, source: .manual)
        cash.accountId = nil
        // Manual transaction on an excluded (holdings) account does NOT count.
        let onExcluded = txn(40, category: "Shopping", account: holdings, source: .manual)
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [cash, onExcluded],
                                                  accounts: [checking, holdings], lookup: [:])
        XCTAssertEqual(result.map(\.category), ["Dining"])     // only the cash one
        XCTAssertEqual(result.first?.total, 25)
        let net = SpendingAnalytics.monthlyNetIncome(transactions: [cash, onExcluded],
                                                     accounts: [checking, holdings], lookup: [:], months: 1)
        XCTAssertEqual(net.first?.value, -25)                  // cash outflow only
    }

    // MARK: Drill-through (SpendContributors)

    /// An itemized $100 Shopping expense like `testItemizedAttribution`, for the detail breakdowns.
    private func itemizedShopping(me: String = "me", splitwiseId: String? = nil) -> Expense {
        Expense(
            id: UUID(), groupId: UUID(), splitwiseExpenseId: splitwiseId, details: "Target run",
            amount: 100, currency: "USD", date: Date(), category: "Shopping",
            createdAt: Date(), updatedAt: Date(),
            splits: [
                Split(id: UUID(), userIdentifier: me, paidShare: 100, owedShare: 85),
                Split(id: UUID(), userIdentifier: "friend", paidShare: 0, owedShare: 15),
            ],
            items: [
                ExpenseItem(id: UUID(), name: "Milk", quantity: 1, price: 40, category: "Groceries", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Soap", quantity: 1, price: 30, category: "Personal Care", ownerIdentifier: me),
                ExpenseItem(id: UUID(), name: "Chips", quantity: 1, price: 20, category: "Snacks", ownerIdentifier: nil),
            ])
    }

    func testDetailedSumsToContributions() {
        let me = "me"
        for exp in [itemizedShopping(me: me), itemizedShopping(me: me, splitwiseId: "sw-1")] {
            let detailed = ItemizedSpend.detailed(for: exp, me: me, lookup: [:])
            var summed: [String: Decimal] = [:]
            for d in detailed { summed[d.category, default: 0] += d.amount }
            let contrib = ItemizedSpend.categoryContributions(for: exp, me: me, lookup: [:])
            XCTAssertEqual(summed, Dictionary(contrib.map { ($0.category, $0.amount) },
                                              uniquingKeysWith: { a, _ in a }))
        }
    }

    func testCategoryContributorsListSourcesAndSum() {
        let checking = account(type: "checking")
        let me = "me"
        let t = txn(30, category: "Dining", account: checking)
        let nonItem = expense(60, category: "Dining", owed: 20, details: "Dinner")
        // An itemized expense with a single Dining item assigned to me (full price).
        let itemized = Expense(
            id: UUID(), groupId: UUID(), details: "Cafe", amount: 50, currency: "USD",
            date: Date(), category: "Shopping", createdAt: Date(), updatedAt: Date(),
            splits: [Split(id: UUID(), userIdentifier: me, paidShare: 50, owedShare: 50)],
            items: [ExpenseItem(id: UUID(), name: "Latte", quantity: 1, price: 50,
                                category: "Dining", ownerIdentifier: me)])
        let txns = [t]; let exps = [nonItem, itemized]
        let rows = SpendContributors.of(scope: .category("Dining"), month: Date(), transactions: txns,
                                        accounts: [checking], expenses: exps, lookup: [:], me: me)
        XCTAssertEqual(rows.count, 3)  // transaction + non-itemized expense + one item
        let txnRows = rows.filter { if case .transaction = $0.source { return true }; return false }
        let expRows = rows.filter { if case .expense = $0.source { return true }; return false }
        XCTAssertEqual(txnRows.count, 1)
        XCTAssertEqual(expRows.count, 2)
        XCTAssertTrue(rows.contains { $0.label == "Cafe · Latte" })  // item row label
        // Rows sum to the category total.
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        let byCat = SpendingAnalytics.byCategory(in: Date(), transactions: txns, accounts: [checking],
                                                 lookup: [:], expenses: exps, me: me)
        XCTAssertEqual(total, byCat.first { $0.category == "Dining" }?.total)
        XCTAssertEqual(total, 100)  // 30 + 20 + 50
    }

    func testSpendingScopeSumsToMonthlySpending() {
        let checking = account(type: "checking")
        let me = "me"
        let txns = [txn(30, category: "Dining", account: checking),
                    txn(20, category: "Groceries", account: checking),
                    txn(-100, category: "Income", account: checking)]  // inflow, excluded from spend
        let exps = [expense(60, category: "Dining", owed: 20)]
        let rows = SpendContributors.of(scope: .spending, month: Date(), transactions: txns,
                                        accounts: [checking], expenses: exps, lookup: [:], me: me)
        XCTAssertFalse(rows.contains { $0.isInflow })  // income not present
        let total = rows.reduce(Decimal(0)) { $0 + $1.amount }
        let monthly = SpendingAnalytics.monthlySpending(transactions: txns, accounts: [checking],
                                                        lookup: [:], months: 1, expenses: exps, me: me)
        XCTAssertEqual(total, monthly.first?.value)
        XCTAssertEqual(total, 70)  // 30 + 20 + 20
    }

    func testCashFlowScopeSignedAndExcludesNeutral() {
        let checking = account(type: "checking")
        let me = "me"
        let txns = [txn(-2000, category: "Income", account: checking),  // inflow
                    txn(300, category: "Groceries", account: checking), // outflow
                    txn(500, category: "Transfer", account: checking)]  // neutral, excluded
        let exps = [expense(60, category: "Dining", owed: 20)]          // outflow
        let rows = SpendContributors.of(scope: .cashFlow, month: Date(), transactions: txns,
                                        accounts: [checking], expenses: exps, lookup: [:], me: me)
        XCTAssertEqual(rows.count, 3)  // income + groceries + dining; transfer dropped
        XCTAssertFalse(rows.contains { $0.category == "Transfer" })
        XCTAssertTrue(rows.contains { $0.isInflow && $0.category == "Income" })
        // Signed rows: net income = −Σ(amount).
        let signed = rows.reduce(Decimal(0)) { $0 + $1.amount }
        let net = SpendingAnalytics.monthlyNetIncome(transactions: txns, accounts: [checking],
                                                     lookup: [:], months: 1, expenses: exps, me: me).first?.value
        XCTAssertEqual(-signed, net)
        XCTAssertEqual(net, 1680)  // 2000 in − 300 − 20
    }

    // MARK: Transaction items

    /// A $100 manual "Shopping" transaction itemized into Groceries $40 + Household $30 (remainder $30).
    private func itemizedTransaction(account: Account) -> Transaction {
        Transaction(
            id: UUID(), accountId: account.id, source: .manual, details: "Target",
            amount: 100, currency: "USD", date: Date(), category: "Shopping",
            items: [
                TransactionItem(id: UUID(), name: "Milk", quantity: 1, price: 40, category: "Groceries"),
                TransactionItem(id: UUID(), name: "Soap", quantity: 1, price: 30, category: "Household"),
            ],
            createdAt: Date(), updatedAt: Date())
    }

    func testTransactionItemsDecomposeAcrossCategories() {
        let checking = account(type: "checking")
        let t = itemizedTransaction(account: checking)
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [t],
                                                  accounts: [checking], lookup: [:])
        let byCat = Dictionary(result.map { ($0.category, $0.total) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byCat["Groceries"], 40)
        XCTAssertEqual(byCat["Household"], 30)
        XCTAssertEqual(byCat["Shopping"], 30)  // remainder under the transaction's own category
        XCTAssertEqual(result.reduce(Decimal(0)) { $0 + $1.total }, 100)  // sums to the transaction amount
        // Monthly spending sees the same total.
        XCTAssertEqual(SpendingAnalytics.monthlySpending(transactions: [t], accounts: [checking],
                                                         lookup: [:], months: 1).first?.value, 100)
    }

    func testTransactionDetailedSumsToAmount() {
        let checking = account(type: "checking")
        let detailed = ItemizedSpend.transactionDetailed(for: itemizedTransaction(account: checking), lookup: [:])
        XCTAssertEqual(detailed.reduce(Decimal(0)) { $0 + $1.amount }, 100)
        XCTAssertTrue(detailed.contains { $0.itemId == nil && $0.amount == 30 })  // the remainder row
        XCTAssertEqual(detailed.filter { $0.itemId != nil }.count, 2)            // one per priced item
    }

    func testTransactionItemContributorsDrillThrough() {
        let checking = account(type: "checking")
        let t = itemizedTransaction(account: checking)
        let rows = SpendContributors.of(scope: .category("Groceries"), month: Date(), transactions: [t],
                                        accounts: [checking], expenses: [], lookup: [:], me: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.label, "Target · Milk")  // "<details> · <item>"
        XCTAssertEqual(rows.first?.amount, 40)
        if case .transaction = rows.first?.source {} else { XCTFail("expected a .transaction source") }
        // The remainder shows under the transaction's category as a non-item row.
        let shopping = SpendContributors.of(scope: .category("Shopping"), month: Date(), transactions: [t],
                                            accounts: [checking], expenses: [], lookup: [:], me: nil)
        XCTAssertEqual(shopping.count, 1)
        XCTAssertEqual(shopping.first?.label, "Target")
        XCTAssertEqual(shopping.first?.amount, 30)
    }

    func testTransactionItemMappingRoundTrip() throws {
        // Draft → input (owner ignored; money as strings).
        let input = Mapping.transactionItemInput(
            ItemDraft(id: UUID(), name: "Milk", quantity: 2, price: 40, category: "Groceries", owner: "ignored"))
        XCTAssertEqual(input.name, "Milk")
        XCTAssertEqual(input.price, "40")
        XCTAssertEqual(input.quantity, "2")
        XCTAssertEqual(input.category, "Groceries")
        // Response → model (provenance carried).
        let now = Date()
        let item = try Mapping.transactionItem(Components.Schemas.TransactionItemResponse(
            id: UUID().uuidString, name: "Milk", quantity: "2", price: "40", category: "Groceries",
            created_by: "me", updated_by: nil, created_at: now, updated_at: now))
        XCTAssertEqual(item.name, "Milk")
        XCTAssertEqual(item.price, 40)
        XCTAssertEqual(item.category, "Groceries")
        XCTAssertEqual(item.addedBy, "me")
    }

    // MARK: SpendPeriod + range analytics

    private func firstOfMonth(_ y: Int, _ m: Int) -> Date {
        SpendingAnalytics.spendCalendar.date(from: DateComponents(year: y, month: m, day: 1))!
    }

    func testSpendPeriodResolveBoundsAndLabels() {
        let cal = SpendingAnalytics.spendCalendar
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let june = firstOfMonth(2026, 6)

        let last6 = SpendPeriod.last6.resolve(anchor: june, now: now)
        XCTAssertEqual(last6.months, 6)
        XCTAssertEqual(last6.end, june)
        XCTAssertEqual(last6.start, firstOfMonth(2026, 1))
        XCTAssertEqual(last6.label, "Last 6 months")

        let ytd = SpendPeriod.yearToDate.resolve(anchor: june, now: now)
        XCTAssertEqual(ytd.start, firstOfMonth(2026, 1))
        XCTAssertEqual(ytd.end, june)
        XCTAssertEqual(ytd.months, 6)
        XCTAssertEqual(ytd.label, "2026 YTD")

        let prev = SpendPeriod.previousYear.resolve(anchor: june, now: now)
        XCTAssertEqual(prev.start, firstOfMonth(2025, 1))
        XCTAssertEqual(prev.end, firstOfMonth(2025, 12))
        XCTAssertEqual(prev.months, 12)
        XCTAssertEqual(prev.label, "2025")

        let month = SpendPeriod.month.resolve(anchor: june, now: now)
        XCTAssertEqual(month.start, june)
        XCTAssertEqual(month.end, june)
        XCTAssertEqual(month.months, 1)
    }

    func testByCategoryRangeSumsAcrossMonths() {
        let checking = account(type: "checking")
        let cal = SpendingAnalytics.spendCalendar
        let thisMonth = SpendingAnalytics.monthStart(Date())
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth)!
        let txns = [txn(20, category: "Dining", account: checking, date: thisMonth),
                    txn(30, category: "Dining", account: checking, date: lastMonth)]
        // A single month sees only its own spend; the two-month range sums both.
        XCTAssertEqual(SpendingAnalytics.byCategory(from: thisMonth, to: thisMonth, transactions: txns,
                                                    accounts: [checking], lookup: [:]).first?.total, 20)
        XCTAssertEqual(SpendingAnalytics.byCategory(from: lastMonth, to: thisMonth, transactions: txns,
                                                    accounts: [checking], lookup: [:]).first?.total, 50)
    }

    func testContributorsRangeSpansMonths() {
        let checking = account(type: "checking")
        let cal = SpendingAnalytics.spendCalendar
        let thisMonth = SpendingAnalytics.monthStart(Date())
        let lastMonth = cal.date(byAdding: .month, value: -1, to: thisMonth)!
        let txns = [txn(20, category: "Dining", account: checking, date: thisMonth),
                    txn(30, category: "Dining", account: checking, date: lastMonth)]
        let rows = SpendContributors.of(scope: .category("Dining"), from: lastMonth, to: thisMonth,
                                        transactions: txns, accounts: [checking], expenses: [],
                                        lookup: [:], me: nil)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(Decimal(0)) { $0 + $1.amount }, 50)
    }

    // MARK: Local categories (seed + backup snapshot)

    func testCategorySnapshotRoundTrip() throws {
        let snap = CategorySnapshot(
            categories: [.init(name: "Coffee", icon: "cup.and.saucer", position: 5, builtin: false)],
            maps: [.init(rawCategory: "FOO_BAR", canonicalCategory: "Dining", source: "manual")])
        let decoded = try JSONDecoder().decode(
            CategorySnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.categories.map(\.name), ["Coffee"])
        XCTAssertEqual(decoded.categories.first?.icon, "cup.and.saucer")
        XCTAssertEqual(decoded.maps.first?.rawCategory, "FOO_BAR")
        XCTAssertEqual(decoded.maps.first?.canonicalCategory, "Dining")
    }

    @MainActor
    func testCategorySeedAndApplyRestoresCustomAndForwardFillsBuiltins() throws {
        let context = ModelContext(try CleaveStore.makeModelContainer(inMemory: true))

        // Fresh store → seed inserts all built-ins, marked builtin.
        CategorySeed.ensureBuiltins(context)
        let seeded = try context.fetch(FetchDescriptor<SpendCategory>())
        XCTAssertEqual(Set(seeded.map(\.name)), Set(CanonicalCategory.all))
        XCTAssertTrue(seeded.allSatisfy(\.builtin))

        // Restore a backup that has a custom category + a map but is missing one built-in ("Pets").
        let kept = CanonicalCategory.all.filter { $0 != "Pets" }
        let snap = CategorySnapshot(
            categories: kept.enumerated().map { .init(name: $1, icon: nil, position: $0, builtin: true) }
                + [.init(name: "Coffee", icon: "cup.and.saucer", position: 99, builtin: false)],
            maps: [.init(rawCategory: "FOO_BAR", canonicalCategory: "Dining", source: "manual")])
        try CategorySync.apply(snap, context)

        let names = Set(try context.fetch(FetchDescriptor<SpendCategory>()).map(\.name))
        XCTAssertTrue(names.contains("Coffee"))                  // custom restored
        XCTAssertTrue(names.contains("Pets"))                    // missing built-in forward-filled
        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        XCTAssertEqual(maps.map(\.rawCategory), ["FOO_BAR"])     // map restored, replacing prior rows
    }

    // MARK: GoalProgress

    func testBudgetStatusAndFraction() {
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 20, target: 100), .under)
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 90, target: 100), .nearing)
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 120, target: 100), .over)
        XCTAssertEqual(GoalProgress.budgetFraction(spent: 20, target: 100), 0.2, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.budgetFraction(spent: 120, target: 100), 1.0, accuracy: 0.0001)
    }

    func testSaveFractionBalanceAndAmount() {
        XCTAssertEqual(GoalProgress.saveFraction(current: 5000, starting: 4000, target: 6000, type: .balance),
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 5000, starting: 4000, target: 2000, type: .amount),
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 6000, starting: 4000, target: 6000, type: .balance),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 4000, starting: 4000, target: 2000, type: .amount),
                       0.0, accuracy: 0.0001)
    }
}
