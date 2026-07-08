import enum


class BackendType(str, enum.Enum):
    self_hosted = "self_hosted"
    splitwise = "splitwise"


class TransactionSource(str, enum.Enum):
    plaid = "plaid"
    manual = "manual"
    simplefin = "simplefin"


class UserSource(str, enum.Enum):
    app = "app"
    manual = "manual"
    splitwise = "splitwise"


class NotificationSource(str, enum.Enum):
    splitwise = "splitwise"
    app = "app"


class ConnectionStatus(str, enum.Enum):
    pending = "pending"
    accepted = "accepted"


class ShareLevel(str, enum.Enum):
    private = "private"      # owner only
    balances = "balances"    # partner sees the balance, not transactions
    full = "full"            # partner sees balance + transactions
