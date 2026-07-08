import XCTest
import Foundation
@testable import CleaveAPI

/// Parity conformance: replays the language-neutral fixtures under `spec/fixtures/**`
/// against the *shipping* Logic layer, proving the fixtures faithfully describe this app.
///
/// This is the ORACLE gate for the client parity contract (see `spec/README.md`). The same
/// fixtures are replayed by the web and Android clients against their reimplementations, so a
/// change to any captured module that diverges from a fixture fails here until the fixture is
/// regenerated intentionally.
///
/// Fixtures are located relative to this source file via `#filePath` (repo checkout layout:
/// `<repo>/ios/CleaveTests/ParityConformanceTests.swift` -> `<repo>/spec/fixtures`), so no
/// bundle-resource wiring is needed and the test reads the same JSON the other clients consume.
final class ParityConformanceTests: XCTestCase {

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)   // .../ios/CleaveTests/ParityConformanceTests.swift
            .deletingLastPathComponent()  // .../ios/CleaveTests
            .deletingLastPathComponent()  // .../ios
            .deletingLastPathComponent()  // .../<repo>
            .appendingPathComponent("spec/fixtures", isDirectory: true)
    }

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    /// Generic envelope: `{ module, cases: [C] }`. Loads and concatenates every `*.json` in a module dir.
    private struct Envelope<C: Decodable>: Decodable { let module: String; let cases: [C] }

    private func loadCases<C: Decodable>(module: String, as: C.Type) throws -> [C] {
        let dir = Self.fixturesRoot.appendingPathComponent(module, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no fixtures under \(dir.path)")
        var cases: [C] = []
        for f in files {
            let env = try JSONDecoder().decode(Envelope<C>.self, from: Data(contentsOf: f))
            XCTAssertEqual(env.module, module, "\(f.lastPathComponent): module tag")
            cases.append(contentsOf: env.cases)
        }
        return cases
    }

    // MARK: - split-math

    private struct SplitCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct ExpenseJSON: Decodable { let details: String; let category: String? }
        struct Input: Decodable {
            let amount: String?; let payer: String?; let participants: [String]?
            let weights: [String: String]?; let adjustments: [String: String]?; let assigned: [String: String]?
            let splits: [SplitJSON]?; let expenses: [ExpenseJSON]?
        }
        struct Expected: Decodable { let splits: [SplitJSON]?; let balanced: Bool?; let visible: [String]?; let collapsed: Int? }
    }

    private func weights(_ d: [String: String]?) -> [String: Decimal] { (d ?? [:]).mapValues { dec($0) } }

    private func assertSplits(_ produced: [SplitDraft], _ expected: [SplitCase.SplitJSON], _ name: String) {
        XCTAssertEqual(produced.count, expected.count, "\(name): split count")
        guard produced.count == expected.count else { return }
        for (p, e) in zip(produced, expected) {
            XCTAssertEqual(p.userIdentifier, e.userIdentifier, "\(name): identifier")
            XCTAssertEqual(p.paidShare, dec(e.paidShare), "\(name): paidShare for \(e.userIdentifier)")
            XCTAssertEqual(p.owedShare, dec(e.owedShare), "\(name): owedShare for \(e.userIdentifier)")
        }
    }

    func testSplitMathConformance() throws {
        for c in try loadCases(module: "split-math", as: SplitCase.self) {
            let i = c.input
            switch c.fn {
            case "equalSplit":
                assertSplits(SplitMath.equalSplit(amount: dec(i.amount!), payer: i.payer!, participants: i.participants!),
                             c.expected.splits!, c.name)
            case "weightedSplit":
                assertSplits(SplitMath.weightedSplit(amount: dec(i.amount!), payer: i.payer!, participants: i.participants!,
                                                     weights: weights(i.weights)), c.expected.splits!, c.name)
            case "adjustmentSplit":
                assertSplits(SplitMath.adjustmentSplit(amount: dec(i.amount!), payer: i.payer!, participants: i.participants!,
                                                       adjustments: weights(i.adjustments)), c.expected.splits!, c.name)
            case "itemizedSplit":
                assertSplits(SplitMath.itemizedSplit(amount: dec(i.amount!), payer: i.payer!, participants: i.participants!,
                                                     assigned: weights(i.assigned)), c.expected.splits!, c.name)
            case "reimbursementSplit":
                assertSplits(SplitMath.reimbursementSplit(amount: dec(i.amount!), payer: i.payer!, participants: i.participants!),
                             c.expected.splits!, c.name)
            case "isBalanced":
                let splits = i.splits!.map { SplitDraft(userIdentifier: $0.userIdentifier,
                                                        paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
                XCTAssertEqual(SplitMath.isBalanced(amount: dec(i.amount!), splits: splits),
                               c.expected.balanced!, "\(c.name): balanced")
            case "collapseOlder":
                let exps = i.expenses!.map {
                    Expense(id: UUID(), groupId: UUID(), details: $0.details, amount: 1, currency: "USD",
                            date: Date(), category: $0.category, createdAt: Date(), updatedAt: Date())
                }
                let r = SettleUp.collapseOlder(exps)
                XCTAssertEqual(r.visible.map(\.details), c.expected.visible!, "\(c.name): visible")
                XCTAssertEqual(r.collapsed, c.expected.collapsed!, "\(c.name): collapsed")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - category

    private struct CategoryCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct TxnJSON: Decodable { let category: String?; let `override`: String?; let refined: String?; let source: String }
        struct Input: Decodable {
            let raw: String?
            let lookup: [String: String]?
            let sources: [String: String]?
            let transaction: TxnJSON?
        }
        struct Expected: Decodable {
            let category: String?
            let source: String?
            let value: String?
            let needsRefinement: Bool?
            let all: [String]?
            let excludedFromSpend: [String]?
            let neutral: [String]?
            let incomeLike: [String]?
        }
    }

    private func originString(_ o: CategoryOrigin) -> String {
        switch o {
        case .override: return "override"
        case .mappedByYou: return "mappedByYou"
        case .mappedByAI: return "mappedByAI"
        case .deterministic: return "deterministic"
        case .aiRefined: return "aiRefined"
        case .explicit: return "explicit"
        case .raw: return "raw"
        }
    }

    private func makeTxn(_ t: CategoryCase.TxnJSON) -> Transaction {
        let tx = Transaction(id: UUID(), accountId: UUID(), source: TransactionSource(rawValue: t.source) ?? .plaid,
                             details: "t", amount: 10, currency: "USD", date: Date(), category: t.category,
                             createdAt: Date(), updatedAt: Date())
        tx.categoryOverride = t.override
        tx.refinedCategory = t.refined
        return tx
    }

    private func assertResolution(_ r: CategoryResolution, _ exp: CategoryCase.Expected, _ name: String) {
        XCTAssertEqual(r.category, exp.category, "\(name): category")
        XCTAssertEqual(originString(r.source), exp.source, "\(name): source")
    }

    func testCategoryConformance() throws {
        for c in try loadCases(module: "category", as: CategoryCase.self) {
            let i = c.input
            switch c.fn {
            case "plaidCanonical":
                XCTAssertEqual(PlaidCategory.canonical(i.raw!), c.expected.category, "\(c.name)")
            case "splitwiseCanonical":
                XCTAssertEqual(SplitwiseCategory.canonical(i.raw!), c.expected.category, "\(c.name)")
            case "plaidHumanized":
                XCTAssertEqual(PlaidCategory.humanized(i.raw!), c.expected.value, "\(c.name)")
            case "plaidDisplayLabel":
                XCTAssertEqual(PlaidCategory.displayLabel(i.raw!), c.expected.value, "\(c.name)")
            case "resolveExpense":
                assertResolution(CategoryMapping.resolve(expenseCategory: i.raw, lookup: i.lookup ?? [:], sources: i.sources ?? [:]),
                                 c.expected, c.name)
            case "resolveTransaction":
                assertResolution(CategoryMapping.resolve(for: makeTxn(i.transaction!), lookup: i.lookup ?? [:], sources: i.sources ?? [:]),
                                 c.expected, c.name)
            case "needsRefinement":
                XCTAssertEqual(CategoryMapping.needsRefinement(makeTxn(i.transaction!), lookup: i.lookup ?? [:]),
                               c.expected.needsRefinement!, "\(c.name)")
            case "canonicalSets":
                XCTAssertEqual(CanonicalCategory.all, c.expected.all!, "\(c.name): taxonomy list")
                XCTAssertEqual(CanonicalCategory.excludedFromSpend, Set(c.expected.excludedFromSpend!), "\(c.name): excludedFromSpend")
                XCTAssertEqual(CanonicalCategory.neutral, Set(c.expected.neutral!), "\(c.name): neutral")
                XCTAssertEqual(CanonicalCategory.incomeLike, Set(c.expected.incomeLike!), "\(c.name): incomeLike")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - itemized-spend

    private struct ItemizedCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct ItemJSON: Decodable { let category: String?; let price: String; let owner: String? }
        struct ExpenseJSON: Decodable { let amount: String; let category: String?; let splitwise: Bool; let splits: [SplitJSON]; let items: [ItemJSON] }
        struct TxnItemJSON: Decodable { let category: String?; let price: String }
        struct TxnJSON: Decodable { let amount: String; let category: String?; let source: String; let items: [TxnItemJSON] }
        struct Input: Decodable { let me: String?; let lookup: [String: String]?; let expense: ExpenseJSON?; let transaction: TxnJSON? }
        struct Expected: Decodable { let byCategory: [String: String]; let total: String? }
    }

    private func makeExpense(_ e: ItemizedCase.ExpenseJSON) -> Expense {
        let splits = e.splits.map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        let items = e.items.map { ExpenseItem(id: UUID(), name: $0.category ?? "item", quantity: 1, price: dec($0.price), category: $0.category, ownerIdentifier: $0.owner) }
        return Expense(id: UUID(), groupId: UUID(), splitwiseExpenseId: e.splitwise ? "sw1" : nil,
                       details: "e", amount: dec(e.amount), currency: "USD", date: Date(), category: e.category,
                       createdAt: Date(), updatedAt: Date(), splits: splits, items: items)
    }

    private func makeItemizedTxn(_ t: ItemizedCase.TxnJSON) -> Transaction {
        let items = t.items.map { TransactionItem(id: UUID(), name: $0.category ?? "item", quantity: 1, price: dec($0.price), category: $0.category) }
        return Transaction(id: UUID(), accountId: UUID(), source: TransactionSource(rawValue: t.source) ?? .plaid,
                           details: "t", amount: dec(t.amount), currency: "USD", date: Date(), category: t.category,
                           items: items, createdAt: Date(), updatedAt: Date())
    }

    private func assertByCategory(_ got: [String: Decimal], _ expected: [String: String], _ name: String) {
        XCTAssertEqual(Set(got.keys), Set(expected.keys), "\(name): categories")
        for (k, v) in expected { XCTAssertEqual(got[k], dec(v), "\(name): \(k)") }
    }

    func testItemizedSpendConformance() throws {
        for c in try loadCases(module: "itemized-spend", as: ItemizedCase.self) {
            switch c.fn {
            case "itemizedContributions":
                let contribs = ItemizedSpend.categoryContributions(for: makeExpense(c.input.expense!),
                                                                   me: c.input.me!, lookup: c.input.lookup ?? [:])
                var got: [String: Decimal] = [:]
                for e in contribs { got[e.category, default: 0] += e.amount }
                assertByCategory(got, c.expected.byCategory, c.name)
            case "transactionItemized":
                let d = ItemizedSpend.transactionDetailed(for: makeItemizedTxn(c.input.transaction!), lookup: c.input.lookup ?? [:])
                var got: [String: Decimal] = [:]
                for e in d { if let cat = e.category { got[cat, default: 0] += e.amount } }
                assertByCategory(got, c.expected.byCategory, c.name)
                if let total = c.expected.total {
                    XCTAssertEqual(d.reduce(Decimal(0)) { $0 + $1.amount }, dec(total), "\(c.name): total")
                }
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - account-classification

    private struct AccountCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct AccountJSON: Decodable {
            let name: String; let displayName: String?; let type: String?; let kindOverride: String?
            let mask: String?; let plaidAccountId: String?
            let includeInSpending: Bool?; let includeInCashFlow: Bool?; let institutionName: String?
        }
        struct Input: Decodable { let type: String?; let canonical: String?; let account: AccountJSON? }
        struct Expected: Decodable {
            let kind: String?
            let countsInSpending: Bool?; let countsInCashFlow: Bool?
            let isPlaid: Bool?; let isImported: Bool?; let isManual: Bool?
            let displayLabel: String?; let maskLabel: String?
        }
    }

    private func makeAccount(_ a: AccountCase.AccountJSON) -> Account {
        Account(id: UUID(), name: a.name, displayName: a.displayName, type: a.type, kindOverride: a.kindOverride,
                mask: a.mask, plaidAccountId: a.plaidAccountId, balance: 0, currency: "USD",
                includeInSpending: a.includeInSpending, includeInCashFlow: a.includeInCashFlow,
                institutionName: a.institutionName, createdAt: Date(), updatedAt: Date())
    }

    func testAccountClassificationConformance() throws {
        for c in try loadCases(module: "account-classification", as: AccountCase.self) {
            switch c.fn {
            case "classify":
                XCTAssertEqual(AccountKind.classify(c.input.type).canonical, c.expected.kind, "\(c.name)")
            case "kindFromCanonical":
                XCTAssertEqual(AccountKind(canonical: c.input.canonical!)?.canonical, c.expected.kind, "\(c.name)")
            case "accountFlags":
                let a = makeAccount(c.input.account!)
                XCTAssertEqual(a.kind.canonical, c.expected.kind, "\(c.name): kind")
                XCTAssertEqual(a.countsInSpending, c.expected.countsInSpending!, "\(c.name): countsInSpending")
                XCTAssertEqual(a.countsInCashFlow, c.expected.countsInCashFlow!, "\(c.name): countsInCashFlow")
                XCTAssertEqual(a.isPlaid, c.expected.isPlaid!, "\(c.name): isPlaid")
                XCTAssertEqual(a.isImported, c.expected.isImported!, "\(c.name): isImported")
                XCTAssertEqual(a.isManual, c.expected.isManual!, "\(c.name): isManual")
                XCTAssertEqual(a.displayLabel, c.expected.displayLabel!, "\(c.name): displayLabel")
                XCTAssertEqual(a.maskLabel, c.expected.maskLabel, "\(c.name): maskLabel")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - spend-engine

    private struct SpendCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct ItemJSON: Decodable { let category: String?; let price: String; let owner: String? }
        struct TxnItemJSON: Decodable { let category: String?; let price: String }
        struct TxnJSON: Decodable {
            let id: String?; let accountId: String?; let source: String; let amount: String; let category: String?
            let includeInSpending: Bool?; let includeInCashFlow: Bool?; let items: [TxnItemJSON]?; let date: String?
        }
        struct AcctJSON: Decodable {
            let id: String; let name: String; let type: String?; let kindOverride: String?
            let includeInSpending: Bool?; let includeInCashFlow: Bool?; let institutionName: String?; let plaidAccountId: String?
        }
        struct ExpJSON: Decodable {
            let id: String?; let groupId: String; let transactionId: String?; let splitwiseExpenseId: String?
            let amount: String; let category: String?; let includeInSpending: Bool?; let includeInCashFlow: Bool?
            let date: String?; let splits: [SplitJSON]?; let items: [ItemJSON]?
        }
        struct GroupJSON: Decodable { let id: String; let includeInSpending: Bool?; let includeInCashFlow: Bool? }
        struct EventJSON: Decodable { let category: String?; let amount: String; let countsInSpending: Bool; let countsInCashFlow: Bool }
        struct Input: Decodable {
            let me: String?; let lookup: [String: String]?; let month: String?
            let transactions: [TxnJSON]?; let accounts: [AcctJSON]?; let expenses: [ExpJSON]?; let groups: [GroupJSON]?
            let event: EventJSON?
        }
        struct Expected: Decodable { let events: [EventJSON]?; let isSpend: Bool?; let byCategory: [String: String]? }
    }

    /// A fresh UUID when the fixture omits an id; **fails loudly** on a present-but-malformed id (a
    /// non-hex character silently minting a random UUID once masked a fixture defect - see the parity
    /// contract history). Use `uuidOrNil` for optional id fields (e.g. `transactionId`).
    private func uuidOrNew(_ s: String?) -> UUID {
        guard let s else { return UUID() }
        guard let u = UUID(uuidString: s) else { XCTFail("invalid UUID in fixture: \(s)"); return UUID() }
        return u
    }
    /// nil when the fixture omits the id; fails loudly on a present-but-malformed id (so a bad id can't
    /// silently no-op a link/reference instead of failing the test).
    private func uuidOrNil(_ s: String?) -> UUID? {
        guard let s else { return nil }
        guard let u = UUID(uuidString: s) else { XCTFail("invalid UUID in fixture: \(s)"); return nil }
        return u
    }
    private func isoDate(_ s: String?) -> Date {
        guard let s else { return Date() }
        return ISO8601DateFormatter().date(from: s) ?? Date()
    }
    private func makeSpendTxn(_ t: SpendCase.TxnJSON) -> Transaction {
        let items = (t.items ?? []).map { TransactionItem(id: UUID(), name: $0.category ?? "item", quantity: 1, price: dec($0.price), category: $0.category) }
        return Transaction(id: uuidOrNew(t.id), accountId: uuidOrNil(t.accountId),
                           source: TransactionSource(rawValue: t.source) ?? .plaid, details: "t",
                           amount: dec(t.amount), currency: "USD", date: isoDate(t.date), category: t.category,
                           includeInSpending: t.includeInSpending, includeInCashFlow: t.includeInCashFlow,
                           items: items, createdAt: Date(), updatedAt: Date())
    }
    private func makeSpendAccount(_ a: SpendCase.AcctJSON) -> Account {
        Account(id: uuidOrNew(a.id), name: a.name, type: a.type, kindOverride: a.kindOverride,
                plaidAccountId: a.plaidAccountId, balance: 0, currency: "USD",
                includeInSpending: a.includeInSpending, includeInCashFlow: a.includeInCashFlow,
                institutionName: a.institutionName, createdAt: Date(), updatedAt: Date())
    }
    private func makeSpendExpense(_ e: SpendCase.ExpJSON) -> Expense {
        let splits = (e.splits ?? []).map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        let items = (e.items ?? []).map { ExpenseItem(id: UUID(), name: $0.category ?? "item", quantity: 1, price: dec($0.price), category: $0.category, ownerIdentifier: $0.owner) }
        return Expense(id: uuidOrNew(e.id), groupId: uuidOrNew(e.groupId), transactionId: uuidOrNil(e.transactionId),
                       splitwiseExpenseId: e.splitwiseExpenseId, details: "e", amount: dec(e.amount), currency: "USD",
                       date: isoDate(e.date), category: e.category, includeInSpending: e.includeInSpending,
                       includeInCashFlow: e.includeInCashFlow, createdAt: Date(), updatedAt: Date(), splits: splits, items: items)
    }
    private func makeGroup(_ g: SpendCase.GroupJSON) -> Group {
        Group(id: uuidOrNew(g.id), name: "g", backendType: .selfHosted,
              includeInSpending: g.includeInSpending, includeInCashFlow: g.includeInCashFlow,
              createdAt: Date(), updatedAt: Date())
    }
    private func assertEvents(_ produced: [SpendEvent], _ expected: [SpendCase.EventJSON], _ name: String) {
        XCTAssertEqual(produced.count, expected.count, "\(name): event count")
        guard produced.count == expected.count else { return }
        for (p, e) in zip(produced, expected) {
            XCTAssertEqual(p.category, e.category, "\(name): category")
            XCTAssertEqual(p.amount, dec(e.amount), "\(name): amount")
            XCTAssertEqual(p.countsInSpending, e.countsInSpending, "\(name): countsInSpending")
            XCTAssertEqual(p.countsInCashFlow, e.countsInCashFlow, "\(name): countsInCashFlow")
        }
    }

    func testSpendEngineConformance() throws {
        for c in try loadCases(module: "spend-engine", as: SpendCase.self) {
            let i = c.input
            switch c.fn {
            case "spendEvents":
                let events = SpendingAnalytics.spendEvents(
                    transactions: (i.transactions ?? []).map(makeSpendTxn),
                    accounts: (i.accounts ?? []).map(makeSpendAccount),
                    lookup: i.lookup ?? [:],
                    expenses: (i.expenses ?? []).map(makeSpendExpense),
                    groups: (i.groups ?? []).map(makeGroup), me: i.me)
                assertEvents(events, c.expected.events!, c.name)
            case "isSpend":
                let ev = i.event!
                let e = SpendEvent(id: UUID(), date: Date(), label: "e", category: ev.category,
                                   amount: dec(ev.amount), countsInSpending: ev.countsInSpending, countsInCashFlow: ev.countsInCashFlow)
                XCTAssertEqual(SpendingAnalytics.isSpend(e), c.expected.isSpend!, "\(c.name)")
            case "byCategory":
                let result = SpendingAnalytics.byCategory(
                    in: isoDate(i.month),
                    transactions: (i.transactions ?? []).map(makeSpendTxn),
                    accounts: (i.accounts ?? []).map(makeSpendAccount),
                    lookup: i.lookup ?? [:],
                    expenses: (i.expenses ?? []).map(makeSpendExpense),
                    groups: (i.groups ?? []).map(makeGroup), me: i.me)
                var got: [String: Decimal] = [:]
                for cs in result { got[cs.category] = cs.total }
                assertByCategory(got, c.expected.byCategory!, c.name)
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - subscriptions

    private struct SubCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct TxnJSON: Decodable { let details: String; let amount: String; let source: String; let category: String?; let date: String }
        struct ExpJSON: Decodable { let details: String; let amount: String; let category: String?; let date: String; let splits: [SplitJSON]? }
        struct SubJSON: Decodable { let id: String; let cadence: String; let latestAmount: String; let priorAmount: String; let annualCost: String; let isShared: Bool; let increased: Bool }
        struct CandJSON: Decodable { let id: String; let cadence: String?; let amount: String; let occurrences: Int; let isShared: Bool }
        struct Input: Decodable {
            let medianDays: Double?; let cadence: String?
            let amount: String?; let ruleAmount: String?
            let latestAmount: String?; let priorAmount: String?
            let me: String?; let lookup: [String: String]?; let transactions: [TxnJSON]?; let expenses: [ExpJSON]?
        }
        struct Expected: Decodable {
            let cadence: String?
            let periodsPerYear: String?; let days: Int?; let unit: String?; let label: String?
            let matches: Bool?
            let annualCost: String?; let monthlyEquivalent: String?; let increased: Bool?
            let subscriptions: [SubJSON]?; let candidates: [CandJSON]?
        }
    }

    private func cadence(from s: String) -> SubscriptionCadence {
        switch s {
        case "weekly": return .weekly
        case "biweekly": return .biweekly
        case "monthly": return .monthly
        case "quarterly": return .quarterly
        default: return .yearly
        }
    }
    private func cadenceName(_ c: SubscriptionCadence) -> String {
        switch c {
        case .weekly: return "weekly"
        case .biweekly: return "biweekly"
        case .monthly: return "monthly"
        case .quarterly: return "quarterly"
        case .yearly: return "yearly"
        }
    }
    private func subTxn(_ t: SubCase.TxnJSON) -> Transaction {
        Transaction(id: UUID(), source: TransactionSource(rawValue: t.source) ?? .plaid, details: t.details,
                    amount: dec(t.amount), currency: "USD", date: isoDate(t.date), category: t.category,
                    createdAt: Date(), updatedAt: Date())
    }
    private func subExpense(_ e: SubCase.ExpJSON) -> Expense {
        let splits = (e.splits ?? []).map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        return Expense(id: UUID(), groupId: UUID(), details: e.details, amount: dec(e.amount), currency: "USD",
                       date: isoDate(e.date), category: e.category, createdAt: Date(), updatedAt: Date(), splits: splits)
    }

    func testSubscriptionConformance() throws {
        for c in try loadCases(module: "subscriptions", as: SubCase.self) {
            let i = c.input
            switch c.fn {
            case "cadenceClassify":
                XCTAssertEqual(SubscriptionCadence.classify(medianDays: i.medianDays!).map(cadenceName), c.expected.cadence, "\(c.name)")
            case "cadenceProps":
                let cad = cadence(from: i.cadence!)
                XCTAssertEqual(cad.periodsPerYear, dec(c.expected.periodsPerYear!), "\(c.name): periodsPerYear")
                XCTAssertEqual(cad.days, c.expected.days!, "\(c.name): days")
                XCTAssertEqual(cad.unit, c.expected.unit!, "\(c.name): unit")
                XCTAssertEqual(cad.label, c.expected.label!, "\(c.name): label")
            case "ruleMatches":
                let rule = SubscriptionRule(merchantKey: "k", amount: dec(i.ruleAmount!), isSubscription: false, displayName: "n")
                XCTAssertEqual(SubscriptionDetector.matches(amount: dec(i.amount!), rule: rule), c.expected.matches!, "\(c.name)")
            case "subscriptionProps":
                let sub = Subscription(id: "x", displayName: "x", cadence: cadence(from: i.cadence!),
                                       latestAmount: dec(i.latestAmount!), priorAmount: i.priorAmount.map(dec),
                                       currency: "USD", nextDate: Date(), lastDate: Date(), isShared: false, charges: [])
                XCTAssertEqual(sub.annualCost, dec(c.expected.annualCost!), "\(c.name): annualCost")
                if let m = c.expected.monthlyEquivalent { XCTAssertEqual(sub.monthlyEquivalent, dec(m), "\(c.name): monthlyEquivalent") }
                XCTAssertEqual(sub.increased, c.expected.increased!, "\(c.name): increased")
            case "detect":
                let result = SubscriptionDetector.analyze(
                    transactions: (i.transactions ?? []).map(subTxn),
                    expenses: (i.expenses ?? []).map(subExpense),
                    lookup: i.lookup ?? [:], me: i.me, rules: [], asOf: Date())
                XCTAssertEqual(result.subscriptions.count, c.expected.subscriptions!.count, "\(c.name): sub count")
                for (s, e) in zip(result.subscriptions, c.expected.subscriptions!) {
                    XCTAssertEqual(s.id, e.id, "\(c.name): sub id")
                    XCTAssertEqual(cadenceName(s.cadence), e.cadence, "\(c.name): sub cadence")
                    XCTAssertEqual(s.latestAmount, dec(e.latestAmount), "\(c.name): latestAmount")
                    XCTAssertEqual(s.priorAmount, Optional(dec(e.priorAmount)), "\(c.name): priorAmount")
                    XCTAssertEqual(s.annualCost, dec(e.annualCost), "\(c.name): annualCost")
                    XCTAssertEqual(s.isShared, e.isShared, "\(c.name): isShared")
                    XCTAssertEqual(s.increased, e.increased, "\(c.name): increased")
                }
                XCTAssertEqual(result.candidates.count, c.expected.candidates!.count, "\(c.name): cand count")
                for (cd, e) in zip(result.candidates, c.expected.candidates!) {
                    XCTAssertEqual(cd.id, e.id, "\(c.name): cand id")
                    XCTAssertEqual(cd.cadence.map(cadenceName), e.cadence, "\(c.name): cand cadence")
                    XCTAssertEqual(cd.amount, dec(e.amount), "\(c.name): cand amount")
                    XCTAssertEqual(cd.occurrences, e.occurrences, "\(c.name): occurrences")
                    XCTAssertEqual(cd.isShared, e.isShared, "\(c.name): cand isShared")
                }
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - matching

    private struct MatchCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct TxnJSON: Decodable { let id: String?; let details: String; let amount: String; let date: String }
        struct ExpJSON: Decodable {
            let id: String?; let transactionId: String?; let amount: String; let date: String
            let details: String; let category: String?; let repeats: Bool?; let splits: [SplitJSON]?
        }
        struct Input: Decodable {
            let score: Double?; let text: String?; let me: String?; let limit: Int?; let windowDays: Int?
            let expense: ExpJSON?; let transactions: [TxnJSON]?; let expenses: [ExpJSON]?
        }
        struct Expected: Decodable { let label: String?; let tokens: [String]?; let order: [String]? }
    }

    private func matchTxn(_ t: MatchCase.TxnJSON) -> Transaction {
        Transaction(id: uuidOrNew(t.id), source: .plaid, details: t.details, amount: dec(t.amount),
                    currency: "USD", date: isoDate(t.date), createdAt: Date(), updatedAt: Date())
    }
    private func matchExpense(_ e: MatchCase.ExpJSON) -> Expense {
        let splits = (e.splits ?? []).map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        return Expense(id: uuidOrNew(e.id), groupId: UUID(), transactionId: uuidOrNil(e.transactionId),
                       details: e.details, amount: dec(e.amount), currency: "USD", date: isoDate(e.date),
                       category: e.category, repeats: e.repeats, createdAt: Date(), updatedAt: Date(), splits: splits)
    }

    func testMatchingConformance() throws {
        for c in try loadCases(module: "matching", as: MatchCase.self) {
            let i = c.input
            switch c.fn {
            case "confidenceLabel":
                XCTAssertEqual(TransactionMatcher.confidenceLabel(i.score!), c.expected.label!, "\(c.name)")
            case "matchTokens":
                XCTAssertEqual(TransactionMatcher.tokens(i.text!), Set(c.expected.tokens!), "\(c.name)")
            case "transactionCandidates":
                let result = TransactionMatcher.transactionCandidates(
                    for: matchExpense(i.expense!),
                    transactions: (i.transactions ?? []).map(matchTxn),
                    expenses: (i.expenses ?? []).map(matchExpense),
                    me: i.me, limit: i.limit ?? 8, windowDays: i.windowDays ?? 21)
                XCTAssertEqual(result.map { $0.transaction.details }, c.expected.order!, "\(c.name)")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - merchant-brand

    private struct MerchBrandCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct ItemJSON: Decodable { let label: String?; let details: String; let amount: String?; let date: String? }
        struct Input: Decodable {
            let text: String?; let merchant: String?; let pattern: String?
            let a: String?; let b: String?
            let seedDescription: String?; let seedAmount: String?; let strictness: String?; let amount: String?
            let items: [ItemJSON]?
        }
        struct Expected: Decodable {
            let key: String?; let words: [String]?; let tokens: [String]?; let cleaned: String?
            let domain: String?; let matches: Bool?; let close: Bool?; let order: [String]?; let displayName: String?
        }
    }

    func testMerchantBrandConformance() throws {
        for c in try loadCases(module: "merchant-brand", as: MerchBrandCase.self) {
            let i = c.input
            switch c.fn {
            case "merchantKey":
                XCTAssertEqual(MerchantText.key(i.text!), c.expected.key!, "\(c.name)")
            case "merchantWords":
                XCTAssertEqual(MerchantText.words(i.text!), c.expected.words!, "\(c.name)")
            case "merchantTokens":
                XCTAssertEqual(MerchantText.tokens(i.text!), Set(c.expected.tokens!), "\(c.name)")
            case "merchantCleaned":
                XCTAssertEqual(MerchantParse.cleaned(i.merchant!), c.expected.cleaned!, "\(c.name)")
            case "embeddedDomain":
                XCTAssertEqual(MerchantParse.embeddedDomain(in: i.text!), c.expected.domain, "\(c.name)")
            case "brandMatch":
                XCTAssertEqual(BrandMatcher.compile(i.pattern!)(i.text!), c.expected.matches!, "\(c.name)")
            case "amountsClose":
                XCTAssertEqual(RelatedTransactions.amountsClose(dec(i.a!), dec(i.b!)), c.expected.close!, "\(c.name)")
            case "relatedGroup":
                let items = i.items!.map { RelatedItemFixture(details: $0.details, amount: dec($0.amount ?? "0"), date: isoDate($0.date), label: $0.label ?? $0.details) }
                let result = RelatedTransactions.group(
                    seedDescription: i.seedDescription!, seedAmount: i.seedAmount.map(dec), in: items,
                    strictness: RelatedTransactions.MatchStrictness(rawValue: i.strictness ?? "balanced")!,
                    amount: RelatedTransactions.AmountMatch(rawValue: i.amount ?? "any")!)
                XCTAssertEqual(result.map { $0.label }, c.expected.order!, "\(c.name)")
            case "commonTokens":
                let items = i.items!.map { RelatedItemFixture(details: $0.details, amount: 0, date: Date(), label: $0.label ?? $0.details) }
                XCTAssertEqual(RelatedTransactions.commonTokens(of: items), c.expected.tokens!, "\(c.name)")
            case "displayName":
                XCTAssertEqual(RelatedTransactions.displayName(for: i.seedDescription!), c.expected.displayName!, "\(c.name)")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }
}

/// A minimal `RelatedItem` for the merchant-brand grouping fixtures - carries a `label` so the
/// grouped result can be checked by fixture id rather than by reconstructing a model.
private struct RelatedItemFixture: RelatedItem {
    let details: String
    let amount: Decimal
    let date: Date
    let label: String
}

extension ParityConformanceTests {

    // MARK: - household-budget

    private struct HouseholdCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct MemberJSON: Decodable { let groupId: String; let userIdentifier: String }
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct ItemJSON: Decodable { let category: String?; let price: String; let owner: String? }
        struct ExpJSON: Decodable {
            let id: String; let groupId: String; let amount: String; let category: String?
            let splitwise: Bool; let date: String; let splits: [SplitJSON]; let items: [ItemJSON]
        }
        struct SpendJSON: Decodable { let mine: String; let partnerTotal: String; let combined: String }
        struct Input: Decodable {
            let viewer: String?; let partners: [String]?; let members: [MemberJSON]?
            let month: String?; let sharedGroupIds: [String]?; let expenses: [ExpJSON]?
        }
        struct Expected: Decodable { let groupIds: [String]?; let byCategory: [String: SpendJSON]? }
    }

    private func makeMember(_ m: HouseholdCase.MemberJSON) -> GroupMember {
        GroupMember(id: UUID(), groupId: uuidOrNew(m.groupId), userIdentifier: m.userIdentifier, createdAt: Date())
    }
    private func makeHouseholdExpense(_ e: HouseholdCase.ExpJSON) -> Expense {
        let splits = e.splits.map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        let items = e.items.map { ExpenseItem(id: UUID(), name: $0.category ?? "item", quantity: 1, price: dec($0.price), category: $0.category, ownerIdentifier: $0.owner) }
        return Expense(id: uuidOrNew(e.id), groupId: uuidOrNew(e.groupId), splitwiseExpenseId: e.splitwise ? "sw1" : nil,
                       details: "e", amount: dec(e.amount), currency: "USD", date: isoDate(e.date), category: e.category,
                       createdAt: Date(), updatedAt: Date(), splits: splits, items: items)
    }

    func testHouseholdBudgetConformance() throws {
        for c in try loadCases(module: "household-budget", as: HouseholdCase.self) {
            let i = c.input
            switch c.fn {
            case "sharedGroups":
                let membership = HouseholdBudget.membership(i.members!.map(makeMember))
                let shared = HouseholdBudget.sharedGroupIds(viewer: i.viewer!, partners: Set(i.partners!), membersByGroup: membership)
                XCTAssertEqual(shared, Set(c.expected.groupIds!.map { UUID(uuidString: $0)! }), "\(c.name)")
            case "combinedByCategory":
                let result = HouseholdBudget.combinedByCategory(
                    month: isoDate(i.month),
                    expenses: i.expenses!.map(makeHouseholdExpense),
                    sharedGroupIds: Set(i.sharedGroupIds!.map { UUID(uuidString: $0)! }),
                    viewer: i.viewer!, partners: Set(i.partners!))
                XCTAssertEqual(Set(result.keys), Set(c.expected.byCategory!.keys), "\(c.name): categories")
                for (cat, e) in c.expected.byCategory! {
                    let spend = result[cat] ?? HouseholdBudget.Spend()
                    XCTAssertEqual(spend.mine, dec(e.mine), "\(c.name): \(cat) mine")
                    XCTAssertEqual(spend.partnerTotal, dec(e.partnerTotal), "\(c.name): \(cat) partnerTotal")
                    XCTAssertEqual(spend.combined, dec(e.combined), "\(c.name): \(cat) combined")
                }
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - goals

    private struct GoalsCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct MonthYM: Decodable { let year: Int; let month: Int }
        struct MonthVal: Decodable { let year: Int; let month: Int; let value: String }
        struct Input: Decodable {
            let spent: String?; let target: String?
            let current: String?; let starting: String?; let type: String?
            let period: String?; let anchor: String?; let now: String?
            let months: Int?; let ending: String?
            let me: String?; let lookup: [String: String]?
            let transactions: [SpendCase.TxnJSON]?; let accounts: [SpendCase.AcctJSON]?
            let expenses: [SpendCase.ExpJSON]?; let groups: [SpendCase.GroupJSON]?
        }
        struct Expected: Decodable {
            let status: String?; let fraction: Double?
            let startYear: Int?; let startMonth: Int?; let endYear: Int?; let endMonth: Int?; let months: Int?
            let range: [MonthYM]?; let values: [MonthVal]?
        }
    }

    private func statusName(_ s: BudgetStatus) -> String {
        switch s { case .under: return "under"; case .nearing: return "nearing"; case .over: return "over" }
    }

    func testGoalsConformance() throws {
        let cal = SpendingAnalytics.spendCalendar
        func assertMonthly(_ vals: [MonthlyValue], _ expected: [GoalsCase.MonthVal], _ name: String) {
            XCTAssertEqual(vals.count, expected.count, "\(name): count")
            guard vals.count == expected.count else { return }
            for (v, e) in zip(vals, expected) {
                XCTAssertEqual(cal.component(.year, from: v.month), e.year, "\(name): year")
                XCTAssertEqual(cal.component(.month, from: v.month), e.month, "\(name): month")
                XCTAssertEqual(v.value, dec(e.value), "\(name): value")
            }
        }
        for c in try loadCases(module: "goals", as: GoalsCase.self) {
            let i = c.input
            switch c.fn {
            case "budgetStatus":
                XCTAssertEqual(statusName(GoalProgress.budgetStatus(spent: dec(i.spent!), target: dec(i.target!))), c.expected.status!, "\(c.name)")
            case "budgetFraction":
                XCTAssertEqual(GoalProgress.budgetFraction(spent: dec(i.spent!), target: dec(i.target!)), c.expected.fraction!, accuracy: 1e-9, "\(c.name)")
            case "saveFraction":
                XCTAssertEqual(GoalProgress.saveFraction(current: dec(i.current!), starting: dec(i.starting!), target: dec(i.target!), type: SaveTargetType(rawValue: i.type!)!), c.expected.fraction!, accuracy: 1e-9, "\(c.name)")
            case "spendPeriod":
                let r = SpendPeriod(rawValue: i.period!)!.resolve(anchor: isoDate(i.anchor!), now: isoDate(i.now!))
                XCTAssertEqual(cal.component(.year, from: r.start), c.expected.startYear!, "\(c.name): startYear")
                XCTAssertEqual(cal.component(.month, from: r.start), c.expected.startMonth!, "\(c.name): startMonth")
                XCTAssertEqual(cal.component(.year, from: r.end), c.expected.endYear!, "\(c.name): endYear")
                XCTAssertEqual(cal.component(.month, from: r.end), c.expected.endMonth!, "\(c.name): endMonth")
                XCTAssertEqual(r.months, c.expected.months!, "\(c.name): months")
            case "monthRange":
                let range = SpendingAnalytics.monthRange(months: i.months!, ending: isoDate(i.ending!), cal: cal)
                XCTAssertEqual(range.count, c.expected.range!.count, "\(c.name): count")
                for (d, e) in zip(range, c.expected.range!) {
                    XCTAssertEqual(cal.component(.year, from: d), e.year, "\(c.name): year")
                    XCTAssertEqual(cal.component(.month, from: d), e.month, "\(c.name): month")
                }
            case "monthlySpending":
                let vals = SpendingAnalytics.monthlySpending(
                    transactions: (i.transactions ?? []).map(makeSpendTxn), accounts: (i.accounts ?? []).map(makeSpendAccount),
                    lookup: i.lookup ?? [:], months: i.months!, ending: isoDate(i.ending!),
                    expenses: (i.expenses ?? []).map(makeSpendExpense), groups: (i.groups ?? []).map(makeGroup), me: i.me)
                assertMonthly(vals, c.expected.values!, c.name)
            case "monthlyNetIncome":
                let vals = SpendingAnalytics.monthlyNetIncome(
                    transactions: (i.transactions ?? []).map(makeSpendTxn), accounts: (i.accounts ?? []).map(makeSpendAccount),
                    lookup: i.lookup ?? [:], months: i.months!, ending: isoDate(i.ending!),
                    expenses: (i.expenses ?? []).map(makeSpendExpense), groups: (i.groups ?? []).map(makeGroup), me: i.me)
                assertMonthly(vals, c.expected.values!, c.name)
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - receipts

    private struct ReceiptCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct Input: Decodable { let text: String?; let date: String?; let now: String?; let window: Int? }
        struct Expected: Decodable { let merchant: String?; let total: String?; let year: Int?; let month: Int?; let day: Int? }
    }

    func testReceiptsConformance() throws {
        let cal = Calendar.current
        for c in try loadCases(module: "receipts", as: ReceiptCase.self) {
            let i = c.input
            switch c.fn {
            case "receiptMerchant":
                XCTAssertEqual(ReceiptHeuristics.parse(i.text!).merchant, c.expected.merchant, "\(c.name)")
            case "receiptTotal":
                XCTAssertEqual(ReceiptHeuristics.parse(i.text!).total, c.expected.total.map(dec), "\(c.name)")
            case "recentReceiptDate":
                let d: Date? = i.date.map { isoDate($0) }
                let r = ExpensePrefill.recentReceiptDate(d, now: isoDate(i.now!), window: i.window ?? 60)
                XCTAssertEqual(cal.component(.year, from: r), c.expected.year!, "\(c.name): year")
                XCTAssertEqual(cal.component(.month, from: r), c.expected.month!, "\(c.name): month")
                XCTAssertEqual(cal.component(.day, from: r), c.expected.day!, "\(c.name): day")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - suggestions

    private struct SuggCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct SuggJSON: Decodable { let id: String?; let kind: String; let sortDate: String?; let matchScore: Double?; let transactionIdCount: Int? }
        struct SplitJSON: Decodable { let userIdentifier: String; let paidShare: String; let owedShare: String }
        struct ExpJSON: Decodable { let id: String; let groupId: String; let transactionId: String?; let category: String?; let details: String; let splits: [SplitJSON] }
        struct TemplateJSON: Decodable { let merchantKey: String; let groupId: String; let shares: [String: Double] }
        struct Input: Decodable {
            let kind: String?; let matchScore: Double?; let transactionIdCount: Int?
            let date: String?; let now: String?
            let suggestions: [SuggJSON]?
            let minOccurrences: Int?; let expenses: [ExpJSON]?
        }
        struct Expected: Decodable {
            let weight: Double?; let confidence: Double?; let recency: Double?
            let order: [String]?; let templates: [TemplateJSON]?
        }
    }

    private func makeSuggestion(id: String, kind: String, sortDate: String?, matchScore: Double?, count: Int?) -> Suggestion {
        var s = Suggestion(id: id, kind: Suggestion.Kind(rawValue: kind)!, title: "", subtitle: "", icon: "", acceptLabel: "")
        s.matchScore = matchScore
        s.sortDate = sortDate.map { isoDate($0) }
        s.transactionIds = (0..<(count ?? 0)).map { _ in UUID() }
        return s
    }
    private func makeTemplateExpense(_ e: SuggCase.ExpJSON) -> Expense {
        let splits = e.splits.map { Split(id: UUID(), userIdentifier: $0.userIdentifier, paidShare: dec($0.paidShare), owedShare: dec($0.owedShare)) }
        return Expense(id: uuidOrNew(e.id), groupId: uuidOrNew(e.groupId), transactionId: uuidOrNil(e.transactionId),
                       details: e.details, amount: 0, currency: "USD", date: Date(), category: e.category,
                       createdAt: Date(), updatedAt: Date(), splits: splits)
    }

    func testSuggestionsConformance() throws {
        for c in try loadCases(module: "suggestions", as: SuggCase.self) {
            let i = c.input
            switch c.fn {
            case "typeWeight":
                XCTAssertEqual(SuggestionRanking.typeWeight(Suggestion.Kind(rawValue: i.kind!)!), c.expected.weight!, "\(c.name)")
            case "suggestionConfidence":
                let s = makeSuggestion(id: "x", kind: i.kind!, sortDate: nil, matchScore: i.matchScore, count: i.transactionIdCount)
                XCTAssertEqual(SuggestionRanking.confidence(s), c.expected.confidence!, accuracy: 1e-9, "\(c.name)")
            case "recency":
                XCTAssertEqual(SuggestionRanking.recency(i.date.map { isoDate($0) }, now: isoDate(i.now!)), c.expected.recency!, accuracy: 1e-9, "\(c.name)")
            case "ranked":
                let suggs = i.suggestions!.map { makeSuggestion(id: $0.id ?? "?", kind: $0.kind, sortDate: $0.sortDate, matchScore: $0.matchScore, count: $0.transactionIdCount) }
                XCTAssertEqual(SuggestionRanking.ranked(suggs, now: isoDate(i.now!)).map { $0.id }, c.expected.order!, "\(c.name)")
            case "deriveTemplates":
                let templates = SplitTemplateLearning.derive(expenses: i.expenses!.map(makeTemplateExpense), minOccurrences: i.minOccurrences ?? 2)
                XCTAssertEqual(templates.count, c.expected.templates!.count, "\(c.name): count")
                let byKey = Dictionary(templates.map { ($0.merchantKey, $0) }, uniquingKeysWith: { a, _ in a })
                for e in c.expected.templates! {
                    guard let t = byKey[e.merchantKey] else { XCTFail("\(c.name): missing \(e.merchantKey)"); continue }
                    XCTAssertEqual(t.groupId, UUID(uuidString: e.groupId)!, "\(c.name): \(e.merchantKey) groupId")
                    XCTAssertEqual(Set(t.shares.keys), Set(e.shares.keys), "\(c.name): \(e.merchantKey) share keys")
                    for (k, v) in e.shares { XCTAssertEqual(t.shares[k] ?? -1, v, accuracy: 1e-9, "\(c.name): \(e.merchantKey) share \(k)") }
                }
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }

    // MARK: - deep-links

    private struct DeepLinkCase: Decodable {
        let name: String, fn: String
        let input: Input, expected: Expected
        struct Input: Decodable { let url: String?; let type: String?; let id: String? }
        struct Expected: Decodable { let api: String?; let invite: String?; let reachable: Bool?; let target: String? }
    }

    func testDeepLinksConformance() throws {
        for c in try loadCases(module: "deep-links", as: DeepLinkCase.self) {
            let i = c.input
            switch c.fn {
            case "joinParse":
                let r = JoinLink.parse(URL(string: i.url!)!)
                if c.expected.api == nil {
                    XCTAssertNil(r?.api, "\(c.name)")
                } else {
                    XCTAssertEqual(r?.api, c.expected.api, "\(c.name): api")
                    XCTAssertEqual(r?.invite, c.expected.invite, "\(c.name): invite")
                }
            case "joinReachable":
                XCTAssertEqual(JoinLink.isPubliclyReachable(i.url!), c.expected.reachable!, "\(c.name)")
            case "ntParse":
                XCTAssertEqual(NotificationTarget(type: i.type, id: i.id)?.id, c.expected.target, "\(c.name)")
            default:
                XCTFail("\(c.name): unknown fn \(c.fn)")
            }
        }
    }
}
