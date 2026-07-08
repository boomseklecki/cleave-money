import XCTest
@testable import CleaveAPI

/// The "broad" nudge cards: shared-budget candidate, overspend, settle-up.
final class SuggestionNudgeTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func members(_ group: UUID, _ ids: [String]) -> [GroupMember] {
        ids.map { GroupMember(id: UUID(), groupId: group, userIdentifier: $0, createdAt: Date()) }
    }

    private func sharedExpense(_ group: UUID, category: String, splits: [(String, Decimal)]) -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, details: "e",
                       amount: splits.reduce(Decimal(0)) { $0 + $1.1 }, currency: "USD", date: Date(),
                       category: category, createdAt: Date(), updatedAt: Date(), splits: s)
    }

    private func goal(_ category: String, target: Decimal, shared: Bool) -> Goal {
        Goal(id: UUID(), kind: "spend", name: category, category: category, targetAmount: target,
             currency: "USD", shared: shared, createdAt: Date(), updatedAt: Date())
    }

    private func nudges(goals: [Goal] = [], transactions: [Transaction] = [], expenses: [Expense] = [],
                        accounts: [Account] = [], groupMembers: [GroupMember] = [],
                        partners: Set<String> = [],
                        friendNets: [(identifier: String, name: String, net: Decimal)] = [],
                        decisions: [SuggestionDecision] = []) -> [Suggestion] {
        SuggestionEngine.nudges(goals: goals, transactions: transactions, expenses: expenses,
                                accounts: accounts, lookup: [:], groupMembers: groupMembers,
                                partners: partners, friendNets: friendNets, decisions: decisions, me: me)
    }

    func testSharedBudgetCandidate() {
        let g = UUID()
        let cards = nudges(expenses: [sharedExpense(g, category: "Dining", splits: [(me, 30), (alex, 30)])],
                           groupMembers: members(g, [me, alex]), partners: [alex])
            .filter { $0.kind == .sharedBudgetCandidate }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.category, "Dining")

        // Suppressed once a shared budget exists for the category.
        let suppressed = nudges(goals: [goal("Dining", target: 100, shared: true)],
                                expenses: [sharedExpense(g, category: "Dining", splits: [(me, 30), (alex, 30)])],
                                groupMembers: members(g, [me, alex]), partners: [alex])
            .filter { $0.kind == .sharedBudgetCandidate }
        XCTAssertTrue(suppressed.isEmpty)
    }

    func testOverspend() {
        let account = Account(id: UUID(), name: "Checking", type: "checking", balance: 0, currency: "USD",
                              createdAt: Date(), updatedAt: Date())
        let txn = Transaction(id: UUID(), accountId: account.id, source: .plaid, details: "Dinner",
                              amount: 100, currency: "USD", date: Date(), category: "FOOD_AND_DRINK",
                              createdAt: Date(), updatedAt: Date())
        let cards = nudges(goals: [goal("Dining", target: 50, shared: false)],
                           transactions: [txn], accounts: [account]).filter { $0.kind == .overspend }
        XCTAssertEqual(cards.count, 1)                       // spent 100 > target 50
        XCTAssertNotNil(cards.first?.goalId)

        let under = nudges(goals: [goal("Dining", target: 500, shared: false)],
                           transactions: [txn], accounts: [account]).filter { $0.kind == .overspend }
        XCTAssertTrue(under.isEmpty)
    }

    private func foodTxn(_ amount: Decimal) -> (Account, Transaction) {
        let a = Account(id: UUID(), name: "Checking", type: "checking", balance: 0, currency: "USD",
                        createdAt: Date(), updatedAt: Date())
        let t = Transaction(id: UUID(), accountId: a.id, source: .plaid, details: "Dinner",
                            amount: amount, currency: "USD", date: Date(), category: "FOOD_AND_DRINK",
                            createdAt: Date(), updatedAt: Date())
        return (a, t)
    }

    func testNearingBudgetAndMutualExclusionWithOverspend() {
        let (a, t) = foodTxn(90)   // 90 of a 100 budget = 90% → nearing, not over
        let cards = nudges(goals: [goal("Dining", target: 100, shared: false)], transactions: [t], accounts: [a])
        XCTAssertEqual(cards.filter { $0.kind == .nearingBudget }.count, 1)
        XCTAssertTrue(cards.filter { $0.kind == .overspend }.isEmpty)
        XCTAssertTrue(cards.first { $0.kind == .nearingBudget }?.subtitle.contains("90%") ?? false)

        // Under 85% → neither card.
        let (a2, t2) = foodTxn(50)
        let none = nudges(goals: [goal("Dining", target: 100, shared: false)], transactions: [t2], accounts: [a2])
        XCTAssertTrue(none.contains { $0.kind == .nearingBudget || $0.kind == .overspend } == false)
    }

    func testNearingDismissalIsMonthScoped() {
        let (a, t) = foodTxn(90)
        let goals = [goal("Dining", target: 100, shared: false)]
        let card = nudges(goals: goals, transactions: [t], accounts: [a]).first { $0.kind == .nearingBudget }!
        XCTAssertTrue(card.id.hasPrefix("nearing:\(goals[0].id.uuidString):"))   // month-scoped id

        // Dismissing this month's card silences it...
        let dismissed = nudges(goals: goals, transactions: [t], accounts: [a],
                               decisions: [SuggestionDecision(key: card.id, decision: "dismissed")])
        XCTAssertTrue(dismissed.filter { $0.kind == .nearingBudget }.isEmpty)
        // ...but an un-scoped (or other-month) key does NOT - so next month re-surfaces.
        let stale = nudges(goals: goals, transactions: [t], accounts: [a],
                           decisions: [SuggestionDecision(key: "nearing:\(goals[0].id.uuidString)",
                                                          decision: "dismissed")])
        XCTAssertEqual(stale.filter { $0.kind == .nearingBudget }.count, 1)
    }

    func testNearingSharedHousehold() {
        let g = UUID()
        let cards = nudges(goals: [goal("Dining", target: 100, shared: true)],
                           expenses: [sharedExpense(g, category: "Dining", splits: [(me, 45), (alex, 45)])],
                           groupMembers: members(g, [me, alex]), partners: [alex])
        XCTAssertEqual(cards.filter { $0.kind == .nearingBudget }.count, 1)   // combined 90 of 100
    }

    func testSettleUp() {
        let over = nudges(friendNets: [(identifier: alex, name: "Alex", net: 20)])
            .filter { $0.kind == .settleUp }
        XCTAssertEqual(over.count, 1)
        XCTAssertEqual(over.first?.friendIdentifier, alex)

        let under = nudges(friendNets: [(identifier: alex, name: "Alex", net: 2)])
            .filter { $0.kind == .settleUp }
        XCTAssertTrue(under.isEmpty)                          // below the threshold
    }

    func testDismissalSuppresses() {
        let decision = SuggestionDecision(key: "settleup:\(alex)", decision: "dismissed")
        let cards = nudges(friendNets: [(identifier: alex, name: "Alex", net: 20)], decisions: [decision])
        XCTAssertTrue(cards.filter { $0.kind == .settleUp }.isEmpty)
    }
}
