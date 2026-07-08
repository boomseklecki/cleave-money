import Foundation

/// Raised when a transport value can't be converted into its SwiftData representation.
enum MappingError: Error, CustomStringConvertible, Equatable {
    case invalidUUID(String, field: String)
    case invalidDecimal(String, field: String)
    case invalidDate(String, field: String)

    var description: String {
        switch self {
        case let .invalidUUID(value, field): return "Invalid UUID \"\(value)\" for \(field)"
        case let .invalidDecimal(value, field): return "Invalid decimal \"\(value)\" for \(field)"
        case let .invalidDate(value, field): return "Invalid date \"\(value)\" for \(field)"
        }
    }
}

/// The single boundary between generated transport types (`Components.Schemas.*`) and SwiftData
/// `@Model` objects. All string→Decimal / string→UUID / string→Date conversion lives here, so the
/// money-storage decision (Decimal today) is changeable in one place.
enum Mapping {
    // POSIX locale so "." is always the decimal separator regardless of device locale.
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `format: date` values arrive as date-only strings ("yyyy-MM-dd"); date-time values are
    /// already decoded to `Date` by the runtime.
    ///
    /// Anchored to the device timezone (not UTC): a date-only value is a calendar date, so it must be parsed
    /// AND displayed in the same zone or it shifts a day. Parsing at UTC midnight while views render in local
    /// time made dates show one day early in negative-UTC offsets. Local midnight keeps the calendar day, and
    /// since this same formatter does outbound `dateOnlyString`, inbound/outbound stay consistent.
    static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = .autoupdatingCurrent
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Scalars

    static func uuid(_ value: String, field: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw MappingError.invalidUUID(value, field: field)
        }
        return uuid
    }

    static func optionalUUID(_ value: String?, field: String) throws -> UUID? {
        guard let value else { return nil }
        return try uuid(value, field: field)
    }

    static func decimal(_ value: String, field: String) throws -> Decimal {
        guard let decimal = Decimal(string: value, locale: posix) else {
            throw MappingError.invalidDecimal(value, field: field)
        }
        return decimal
    }

    static func optionalDecimal(_ value: String?, field: String) throws -> Decimal? {
        guard let value else { return nil }
        return try decimal(value, field: field)
    }

    static func optionalDateOnly(_ value: String?, field: String) throws -> Date? {
        guard let value else { return nil }
        return try dateOnly(value, field: field)
    }

    static func dateOnly(_ value: String, field: String) throws -> Date {
        // Round-trip check: DateFormatter is lenient about separators ("2026/06/18" would parse),
        // so require the value to format back identically.
        guard let date = dateOnlyFormatter.date(from: value),
              dateOnlyFormatter.string(from: date) == value else {
            throw MappingError.invalidDate(value, field: field)
        }
        return date
    }

    // MARK: Enums

    static func backendType(_ value: Components.Schemas.BackendType) -> BackendType {
        switch value {
        case .self_hosted: return .selfHosted
        case .splitwise: return .splitwise
        }
    }

    static func transactionSource(_ value: Components.Schemas.TransactionSource) -> TransactionSource {
        switch value {
        case .plaid: return .plaid
        case .manual: return .manual
        case .simplefin: return .simplefin
        }
    }

    static func userSource(_ value: Components.Schemas.UserSource) -> UserSource {
        switch value {
        case .app: return .app
        case .manual: return .manual
        case .splitwise: return .splitwise
        }
    }

    // MARK: Models

    /// Encodes a value (e.g. the untyped Splitwise repayments array) to a compact JSON string for
    /// raw persistence. Returns nil for nil input or on failure.
    static func jsonString<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        return (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func group(_ r: Components.Schemas.GroupResponse) throws -> Group {
        let group = Group(
            id: try uuid(r.id, field: "Group.id"),
            name: r.name,
            backendType: backendType(r.backend_type),
            splitwiseGroupId: r.splitwise_group_id,
            groupType: r.group_type,
            avatarURL: r.avatar_url,
            coverPhotoURL: r.cover_photo_url,
            hidden: r.hidden,
            includeInSpending: r.include_in_spending,
            includeInCashFlow: r.include_in_cash_flow,
            supersededAt: r.superseded_at,
            createdAt: r.created_at,
            updatedAt: r.updated_at
        )
        group.hasCustomAvatar = r.has_custom_avatar ?? false
        group.avatarCropScale = r.avatar_crop?.scale
        group.avatarCropDx = r.avatar_crop?.dx
        group.avatarCropDy = r.avatar_crop?.dy
        return group
    }

    static func account(_ r: Components.Schemas.AccountResponse) throws -> Account {
        Account(
            id: try uuid(r.id, field: "Account.id"),
            name: r.name,
            displayName: r.display_name,
            type: r._type,
            kindOverride: r.kind,
            mask: r.mask,
            plaidAccountId: r.plaid_account_id,
            plaidItemId: nil,
            balance: try decimal(r.balance, field: "Account.balance"),
            availableBalance: r.available_balance.flatMap { try? decimal($0, field: "Account.available_balance") },
            currency: r.currency,
            includeInSpending: r.include_in_spending,
            includeInCashFlow: r.include_in_cash_flow,
            institutionName: r.institution_name,
            institutionDomain: r.institution_domain,
            institutionColor: r.institution_color,
            institutionStatus: r.institution_status,
            shareLevel: r.share_level,
            createdAt: r.created_at,
            updatedAt: r.updated_at
        )
    }

    static func goal(_ r: Components.Schemas.GoalResponse) throws -> Goal {
        Goal(
            id: try uuid(r.id, field: "Goal.id"),
            kind: r.kind,
            name: r.name,
            category: r.category,
            accountId: try optionalUUID(r.account_id, field: "Goal.account_id"),
            targetAmount: try decimal(r.target_amount, field: "Goal.target_amount"),
            saveTargetType: r.save_target_type,
            startingBalance: try optionalDecimal(r.starting_balance, field: "Goal.starting_balance"),
            startingDate: try optionalDateOnly(r.starting_date, field: "Goal.starting_date"),
            period: r.period,
            currency: r.currency,
            archivedAt: r.archived_at,
            shared: r.shared ?? false,
            createdAt: r.created_at,
            updatedAt: r.updated_at
        )
    }

    static func transaction(_ r: Components.Schemas.TransactionResponse) throws -> Transaction {
        Transaction(
            id: try uuid(r.id, field: "Transaction.id"),
            accountId: try optionalUUID(r.account_id, field: "Transaction.account_id"),
            plaidTransactionId: r.plaid_transaction_id,
            pendingTransactionId: r.pending_transaction_id,
            source: transactionSource(r.source),
            details: r.description,
            amount: try decimal(r.amount, field: "Transaction.amount"),
            currency: r.currency,
            date: try dateOnly(r.date, field: "Transaction.date"),
            category: r.category,
            categoryOverride: r.category_override,
            includeInSpending: r.include_in_spending,
            includeInCashFlow: r.include_in_cash_flow,
            note: r.note,
            pending: r.pending,
            linkedExpenseId: try optionalUUID(r.linked_expense_id, field: "Transaction.linked_expense_id"),
            createdAt: r.created_at,
            updatedAt: r.updated_at
        )
    }

    static func split(_ r: Components.Schemas.SplitResponse) throws -> Split {
        Split(
            id: try uuid(r.id, field: "Split.id"),
            userIdentifier: r.user_identifier,
            paidShare: try decimal(r.paid_share, field: "Split.paid_share"),
            owedShare: try decimal(r.owed_share, field: "Split.owed_share")
        )
    }

    static func item(_ r: Components.Schemas.ItemResponse) throws -> ExpenseItem {
        ExpenseItem(
            id: try uuid(r.id, field: "ItemResponse.id"),
            name: r.name,
            quantity: try decimal(r.quantity, field: "ItemResponse.quantity"),
            price: try decimal(r.price, field: "ItemResponse.price"),
            category: r.category,
            ownerIdentifier: r.owner_identifier,
            addedBy: r.created_by,
            editedBy: r.updated_by,
            addedOn: r.created_at,
            editedOn: r.updated_at
        )
    }

    static func transactionItem(_ r: Components.Schemas.TransactionItemResponse) throws -> TransactionItem {
        TransactionItem(
            id: try uuid(r.id, field: "TransactionItemResponse.id"),
            name: r.name,
            quantity: try decimal(r.quantity, field: "TransactionItemResponse.quantity"),
            price: try decimal(r.price, field: "TransactionItemResponse.price"),
            category: r.category,
            addedBy: r.created_by,
            editedBy: r.updated_by,
            addedOn: r.created_at,
            editedOn: r.updated_at
        )
    }

    static func receipt(_ r: Components.Schemas.ReceiptResponse) throws -> Receipt {
        Receipt(
            id: try uuid(r.id, field: "Receipt.id"),
            bucket: r.bucket,
            objectKey: r.object_key,
            contentType: r.content_type,
            createdAt: r.created_at
        )
    }

    static func expense(_ r: Components.Schemas.ExpenseResponse) throws -> Expense {
        Expense(
            id: try uuid(r.id, field: "Expense.id"),
            groupId: try uuid(r.group_id, field: "Expense.group_id"),
            transactionId: try optionalUUID(r.transaction_id, field: "Expense.transaction_id"),
            splitwiseExpenseId: r.splitwise_expense_id,
            details: r.description,
            amount: try decimal(r.amount, field: "Expense.amount"),
            currency: r.currency,
            date: try dateOnly(r.date, field: "Expense.date"),
            category: r.category,
            createdByIdentifier: r.created_by,
            updatedByIdentifier: r.updated_by,
            splitwiseCreatedAt: r.splitwise_created_at,
            splitwiseUpdatedAt: r.splitwise_updated_at,
            notes: r.notes,
            commentsCount: r.comments_count,
            repeats: r.repeats,
            repeatInterval: r.repeat_interval,
            expenseBundleId: r.expense_bundle_id,
            splitwiseReceiptURL: r.splitwise_receipt_url,
            splitwiseRepayments: jsonString(r.repayments),
            includeInSpending: r.include_in_spending,
            includeInCashFlow: r.include_in_cash_flow,
            note: r.note,
            createdAt: r.created_at,
            updatedAt: r.updated_at,
            splits: try (r.splits ?? []).map(split),
            items: try (r.items ?? []).map(item),
            receipts: try (r.receipts ?? []).map(receipt)
        )
    }

    static func user(_ r: Components.Schemas.UserResponse) throws -> User {
        User(
            id: try uuid(r.id, field: "User.id"),
            identifier: r.identifier,
            displayName: r.display_name,
            source: userSource(r.source),
            splitwiseUserId: r.splitwise_user_id,
            email: r.email,
            avatarURL: r.avatar_url,
            registrationStatus: r.registration_status,
            createdAt: r.created_at,
            updatedAt: r.updated_at
        )
    }

    static func groupMember(_ r: Components.Schemas.GroupMemberResponse) throws -> GroupMember {
        GroupMember(
            id: try uuid(r.id, field: "GroupMember.id"),
            groupId: try uuid(r.group_id, field: "GroupMember.group_id"),
            userIdentifier: r.user_identifier,
            createdAt: r.created_at
        )
    }

    static func balance(_ r: Components.Schemas.BalanceEntry) throws -> Balance {
        Balance(
            identifier: r.identifier,
            displayName: r.display_name,
            paidTotal: try decimal(r.paid_total, field: "Balance.paid_total"),
            owedTotal: try decimal(r.owed_total, field: "Balance.owed_total"),
            net: try decimal(r.net, field: "Balance.net")
        )
    }

    // MARK: Reverse (SwiftData/draft → request schema)

    /// Decimal → plain string for the (collapsed) money request fields.
    static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func dateOnlyString(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    static func apiUserSource(_ value: UserSource) -> Components.Schemas.UserSource {
        switch value {
        case .app: return .app
        case .manual: return .manual
        case .splitwise: return .splitwise
        }
    }

    static func splitInput(_ d: SplitDraft) -> Components.Schemas.SplitInput {
        .init(
            user_identifier: d.userIdentifier,
            paid_share: decimalString(d.paidShare),
            owed_share: decimalString(d.owedShare)
        )
    }

    static func itemInput(_ d: ItemDraft) -> Components.Schemas.ItemInput {
        .init(
            id: d.id?.uuidString,
            name: d.name,
            quantity: decimalString(d.quantity),
            price: decimalString(d.price),
            category: d.category,
            owner_identifier: d.owner
        )
    }

    /// A transaction line item input (reuses `ItemDraft`; `owner` is ignored - transactions have no owner).
    static func transactionItemInput(_ d: ItemDraft) -> Components.Schemas.TransactionItemInput {
        .init(
            id: d.id?.uuidString,
            name: d.name,
            quantity: decimalString(d.quantity),
            price: decimalString(d.price),
            category: d.category
        )
    }

    static func expenseCreate(_ d: ExpenseDraft) -> Components.Schemas.ExpenseCreate {
        .init(
            group_id: d.groupId.uuidString,
            description: d.details,
            amount: decimalString(d.amount),
            currency: d.currency,
            date: dateOnlyString(d.date),
            category: d.category,
            notes: d.notes,
            created_by: d.createdBy,
            transaction_id: d.transactionId?.uuidString,
            splits: d.splits.map(splitInput),
            items: d.items.map(itemInput)
        )
    }

    static func expenseUpdate(_ d: ExpenseDraft) -> Components.Schemas.ExpenseUpdate {
        .init(
            group_id: d.groupId.uuidString,
            description: d.details,
            amount: decimalString(d.amount),
            currency: d.currency,
            date: dateOnlyString(d.date),
            category: d.category,
            notes: d.notes,
            updated_by: d.updatedBy,
            transaction_id: d.transactionId?.uuidString,
            splits: d.splits.map(splitInput),
            items: d.items.map(itemInput)
        )
    }

    static func userCreate(_ d: UserDraft) -> Components.Schemas.UserCreate {
        .init(
            display_name: d.displayName,
            identifier: d.identifier,
            source: d.source.map(apiUserSource),
            splitwise_user_id: d.splitwiseUserId,
            email: d.email
        )
    }

    static func transactionCreate(_ d: TransactionDraft) -> Components.Schemas.TransactionCreate {
        .init(
            account_id: d.accountId?.uuidString,
            description: d.details,
            amount: decimalString(d.amount),
            currency: d.currency,
            date: dateOnlyString(d.date),
            category: d.category,
            pending: d.pending
        )
    }

    static func goalCreate(_ d: GoalDraft) -> Components.Schemas.GoalCreate {
        .init(
            kind: d.kind.rawValue,
            name: d.name,
            category: d.category,
            account_id: d.accountId?.uuidString,
            target_amount: decimalString(d.targetAmount),
            save_target_type: d.saveTargetType?.rawValue,
            starting_balance: d.startingBalance.map(decimalString),
            starting_date: d.startingDate.map(dateOnlyString),
            period: d.period,
            currency: d.currency,
            shared: d.shared
        )
    }

    static func goalUpdate(_ d: GoalDraft) -> Components.Schemas.GoalUpdate {
        .init(
            name: d.name,
            category: d.category,
            account_id: d.accountId?.uuidString,
            target_amount: decimalString(d.targetAmount),
            save_target_type: d.saveTargetType?.rawValue,
            starting_balance: d.startingBalance.map(decimalString),
            starting_date: d.startingDate.map(dateOnlyString),
            period: d.period,
            currency: d.currency,
            shared: d.shared
        )
    }

    static func accountCreate(name: String, type: String?, balance: Decimal,
                              currency: String?) -> Components.Schemas.AccountCreate {
        .init(name: name, _type: type, balance: decimalString(balance), currency: currency)
    }

    static func accountUpdate(displayName: String? = nil, kind: String? = nil,
                              includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil,
                              shareLevel: String? = nil)
        -> Components.Schemas.AccountUpdate {
        .init(display_name: displayName, kind: kind,
              include_in_spending: includeInSpending, include_in_cash_flow: includeInCashFlow,
              share_level: shareLevel)
    }
}

/// A computed balance row for a participant (value type; fetched on demand, not cached).
/// `net > 0` means the household owes this person.
struct Balance: Equatable, Identifiable {
    var identifier: String
    var displayName: String?
    var paidTotal: Decimal
    var owedTotal: Decimal
    var net: Decimal
    var id: String { identifier }
}

/// Draft value types the UI builds; repositories convert them to request schemas via `Mapping`.
struct ExpenseDraft {
    var groupId: UUID
    var details: String
    var amount: Decimal
    var currency: String? = nil
    var date: Date
    var category: String? = nil
    var notes: String? = nil
    /// Who added (on create) / edited (on update) the expense - the signed-in user.
    var createdBy: String? = nil
    var updatedBy: String? = nil
    var transactionId: UUID? = nil
    var splits: [SplitDraft] = []
    var items: [ItemDraft] = []
}

struct SplitDraft {
    var userIdentifier: String
    var paidShare: Decimal
    var owedShare: Decimal
}

struct ItemDraft {
    var id: UUID? = nil  // existing item (round-trips identity so edits preserve provenance); nil = new
    var name: String
    var quantity: Decimal = 1
    var price: Decimal
    var category: String? = nil
    var owner: String? = nil
}

struct UserDraft {
    var displayName: String
    var identifier: String? = nil
    var source: UserSource? = nil
    var splitwiseUserId: String? = nil
    var email: String? = nil
}

struct TransactionDraft {
    var accountId: UUID? = nil
    var details: String
    var amount: Decimal
    var currency: String? = nil
    var date: Date
    var category: String? = nil
    var pending: Bool = false
}

struct GoalDraft {
    var kind: GoalKind
    var name: String
    var category: String? = nil
    var accountId: UUID? = nil
    var targetAmount: Decimal
    var saveTargetType: SaveTargetType? = nil
    var startingBalance: Decimal? = nil
    var startingDate: Date? = nil
    var period: String = "monthly"
    var currency: String? = nil
    var shared: Bool = false
}
