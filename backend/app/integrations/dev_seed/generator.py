"""Pure synthetic data generator for the development backend.

Produces realistic-but-fake Splitwise-style groups/users/expenses/splits/items so a dev backend can be
populated without any real PII. It reads nothing - given a self identifier and an RNG seed it returns plain
dataclasses that `app.cli.seed_dev` persists. The self identifier is kept verbatim (so you sign into dev as
yourself); everyone else is invented. Every expense's splits balance to the cent (sum(paid)==sum(owed)==
amount), satisfying the `_validate_splits` ±0.01 rule.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal

from app.categories import CATEGORIES


@dataclass
class SeedUser:
    identifier: str
    display_name: str
    source: str = "manual"  # "app" for self, "manual" for invented people
    avatar: str | None = None  # bundled asset filename for a seeded custom avatar (see dev_seed/assets)


@dataclass
class SeedItem:
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None


@dataclass
class SeedSplit:
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


@dataclass
class SeedExpense:
    description: str
    amount: Decimal
    currency: str
    date: date
    category: str | None
    created_by: str
    splits: list[SeedSplit]
    items: list[SeedItem] = field(default_factory=list)
    key: str | None = None  # handle for linking a transaction to this expense (SeedData.links)


@dataclass
class SeedGroup:
    name: str
    group_type: str | None
    members: list[str]
    expenses: list[SeedExpense]
    avatar: str | None = None  # bundled asset filename for a seeded custom group photo (see dev_seed/assets)


@dataclass
class SeedAccount:
    key: str  # local handle linking transactions/goals to this account (owner-prefixed, globally unique)
    owner: str
    name: str
    type: str
    balance: Decimal
    institution_name: str | None = None
    institution_domain: str | None = None
    institution_color: str | None = None
    mask: str | None = None
    available_balance: Decimal | None = None
    share_level: str = "private"  # "private" | "balances" | "full" (owner's outbound sharing choice)


@dataclass
class SeedTransaction:
    owner: str
    account_key: str | None
    description: str
    amount: Decimal  # outflow positive; income/inflow negative
    currency: str
    date: date
    category: str | None
    key: str | None = None   # handle for linking / overriding this transaction
    pending: bool = False


@dataclass
class SeedCategoryMap:
    raw_category: str
    canonical_category: str
    source: str = "manual"  # "manual" | "ondevice"


@dataclass
class SeedOverride:
    transaction_key: str
    category: str | None = None          # explicit user recategorization (highest precedence)
    refined_category: str | None = None  # on-device AI refinement of a vague row (lower precedence)
    note: str | None = None


@dataclass
class SeedGoal:
    kind: str  # "spend" | "save"
    owner: str
    name: str
    category: str | None = None
    account_key: str | None = None
    target_amount: Decimal = Decimal("0")
    save_target_type: str | None = None
    starting_balance: Decimal | None = None


@dataclass
class SeedData:
    users: list[SeedUser]
    groups: list[SeedGroup]
    accounts: list[SeedAccount] = field(default_factory=list)
    transactions: list[SeedTransaction] = field(default_factory=list)
    goals: list[SeedGoal] = field(default_factory=list)
    # Demo enrichment (populated for the self identity so the guest app shows every feature).
    partner: SeedUser | None = None                                    # a connected partner (read-only shares)
    connections: list[tuple[str, str]] = field(default_factory=list)   # accepted (requester, addressee) pairs
    category_names: list[str] = field(default_factory=list)            # the owner's taxonomy (spend_categories)
    category_maps: list[SeedCategoryMap] = field(default_factory=list)
    overrides: list[SeedOverride] = field(default_factory=list)        # per-transaction recategorizations
    links: list[tuple[str, str]] = field(default_factory=list)         # (expense_key, transaction_key) pairs


# Fake people (display name -> identifier is the lowercased name). Picked deterministically.
_PEOPLE = ["Robin", "Sam", "Alex", "Jordan", "Casey", "Riley"]

# Per-category merchant/description pools and plausible amount ranges (dollars). Names are REAL consumer
# brands so their favicons resolve through the brand catalog (`brand_overrides`, migration 0054/0058) - the
# on-device brand model isn't available in the Simulator, so a catalog hit is the only way a demo row shows a
# logo. A few deliberately generic entries (Monthly Rent, City Water, Metro Transit) stay logo-less, as real
# municipal/landlord charges do.
_CATALOG: dict[str, tuple[tuple[int, int], list[str]]] = {
    "Groceries": ((25, 140), ["Whole Foods Market", "Trader Joe's", "Safeway", "Costco Wholesale"]),
    "Dining": ((18, 95), ["Chipotle", "Sweetgreen", "Shake Shack", "Panera Bread"]),
    "Utilities": ((45, 180), ["Xfinity", "Verizon", "City Water", "PG&E"]),
    "Rent": ((1400, 2200), ["Monthly Rent"]),
    "Household": ((12, 80), ["The Home Depot", "IKEA", "Target"]),
    "Entertainment": ((15, 70), ["AMC Theatres", "Steam", "Spotify"]),
    "Travel": ((80, 420), ["Delta Air Lines", "Airbnb", "Marriott"]),
    "Fuel": ((28, 65), ["Shell", "Chevron", "Exxon"]),
    "Transport": ((8, 45), ["Uber", "Lyft", "Metro Transit"]),
}

_GROCERY_ITEMS = ["Milk", "Eggs", "Bread", "Coffee", "Produce", "Chicken", "Pasta", "Cheese", "Snacks"]

# Personal bank-transaction categories (amount range + merchant pool). Unlike the group EXPENSES above
# (which people name themselves, so they stay clean), these mimic what Plaid / a statement import actually
# delivers: raw card descriptors with processor prefixes (TST*, SQ *), store numbers, phones and cities. The
# brand keyword is kept somewhere in the string so the catalog still resolves a favicon (the on-device model
# that would clean "WHOLEFDS MKT #10234" -> Whole Foods isn't available in the Simulator). Abbreviated
# descriptors that drop the full name (WHOLEFDS, AMZN, SBUX) are covered by patterns added in migration 0059.
_BANK_SPEND: dict[str, tuple[tuple[int, int], list[str]]] = {
    "Groceries": ((20, 120), ["WHOLEFDS MKT #10234", "TRADER JOE'S #423 QPS", "SAFEWAY #1734 SAN FRAN"]),
    "Dining": ((12, 70), ["TST* CHIPOTLE 2434", "SBUX STORE #05123", "SQ *SWEETGREEN", "PANERA BREAD #601218"]),
    "Fuel": ((28, 65), ["SHELL OIL 57442136", "CHEVRON 00904 SAN JOSE", "EXXONMOBIL 97243318"]),
    "Transport": ((8, 45), ["UBER *TRIP HELP.UBER.COM", "LYFT *RIDE FRI 8PM", "MTA*NYCT PAYGO"]),
    "Entertainment": ((10, 60), ["AMC ONLINE 6100442", "STEAM PURCHASE 425-889", "NETFLIX.COM"]),
    "Shopping": ((15, 180), ["AMZN Mktp US*2Z9QT", "TARGET 00023456", "BEST BUY #00012", "NIKE.COM 800-806"]),
    "Utilities": ((45, 160), ["COMCAST XFINITY 800-934", "VERIZON *WIRELESS PMT", "CITY OF SF WATER"]),
}

# Subscriptions are emitted separately from the random draw above (each recurs monthly on a fixed day for a
# fixed amount) so they read as regular recurring bills - not the clustered random dates a plain draw produces.
_SUBSCRIPTIONS: list[tuple[str, Decimal]] = [
    ("NETFLIX.COM", Decimal("15.49")),
    ("Spotify USA 877-778", Decimal("11.99")),
    ("DISNEY PLUS", Decimal("13.99")),
    ("Audible*9U2AB1DE1", Decimal("14.95")),
    ("HBOMAX *SUBSCRIPTION", Decimal("15.99")),
    ("ADOBE *CREATIVE CLD", Decimal("22.99")),
]


# Branding for the 3 seeded accounts (checking, credit, savings), so rows show real logos/names.
_INSTITUTIONS = [
    ("Chase", "chase.com", "#117ACA"),
    ("American Express", "americanexpress.com", "#006FCF"),
    ("Ally", "ally.com", "#6C1D45"),
]


def _money(rng: random.Random, lo: int, hi: int) -> Decimal:
    cents = rng.randint(lo * 100, hi * 100)
    return (Decimal(cents) / 100).quantize(Decimal("0.01"))


def _equal_owed(amount: Decimal, members: list[str]) -> dict[str, Decimal]:
    """Split `amount` into per-member owed shares, distributing remainder cents to the first members so the
    shares sum exactly to `amount`."""
    cents = int((amount * 100).to_integral_value())
    base, rem = divmod(cents, len(members))
    return {
        m: (Decimal(base + (1 if i < rem else 0)) / 100)
        for i, m in enumerate(members)
    }


def _splits(amount: Decimal, members: list[str], payer: str) -> list[SeedSplit]:
    owed = _equal_owed(amount, members)
    return [
        SeedSplit(user_identifier=m,
                  paid_share=amount if m == payer else Decimal("0.00"),
                  owed_share=owed[m])
        for m in members
    ]


def _grocery_items(rng: random.Random, total: Decimal) -> tuple[Decimal, list[SeedItem]]:
    """A handful of items whose prices sum exactly to a fresh total (returned alongside)."""
    count = rng.randint(3, 6)
    names = rng.sample(_GROCERY_ITEMS, count)
    items = [SeedItem(name=n, quantity=Decimal("1"),
                      price=_money(rng, 3, 18),
                      category="Groceries") for n in names]
    total = sum((i.price for i in items), Decimal("0.00"))
    return total, items


def _expense(rng: random.Random, category: str, members: list[str], day: date,
             currency: str, itemized: bool, merchant: str | None = None) -> SeedExpense:
    (lo, hi), merchants = _CATALOG[category]
    payer = rng.choice(members)
    items: list[SeedItem] = []
    if itemized and category == "Groceries":
        amount, items = _grocery_items(rng, Decimal("0"))
    else:
        amount = _money(rng, lo, hi)
    description = merchant or rng.choice(merchants)
    return SeedExpense(
        description=description, amount=amount, currency=currency, date=day,
        category=category, created_by=payer,
        splits=_splits(amount, members, payer), items=items,
    )


def _finances(owner: str, rng: random.Random, today: date, currency: str):
    """One persona's personal finances (accounts/transactions/goals), all owned by `owner`. Account keys
    are owner-prefixed so they're unique across personas. Balances/merchants vary per `rng`."""
    def days_ago(n: int) -> date:
        return today - timedelta(days=n)

    savings_balance = _money(rng, 4000, 20000)

    def _mask() -> str:
        return f"{rng.randint(0, 9999):04d}"

    checking_bal = _money(rng, 1500, 6000)
    credit_bal = _money(rng, 200, 1500)
    (chk_i, chk_d, chk_c), (crd_i, crd_d, crd_c), (sav_i, sav_d, sav_c) = _INSTITUTIONS
    accounts = [
        SeedAccount(f"{owner}:checking", owner, "Everyday Checking", "checking", checking_bal,
                    institution_name=chk_i, institution_domain=chk_d, institution_color=chk_c,
                    mask=_mask(), available_balance=checking_bal),
        # A credit card's "available" is remaining credit, not the balance - leave it unset.
        SeedAccount(f"{owner}:credit", owner, "Rewards Card", "credit card", credit_bal,
                    institution_name=crd_i, institution_domain=crd_d, institution_color=crd_c, mask=_mask()),
        SeedAccount(f"{owner}:savings", owner, "High-Yield Savings", "savings", savings_balance,
                    institution_name=sav_i, institution_domain=sav_d, institution_color=sav_c,
                    mask=_mask(), available_balance=savings_balance),
    ]
    # A fixed monthly paycheck + two subscriptions the persona keeps: each recurs once per month on a stable
    # day for the same amount (so they look like real recurring bills and drive recurring-bill detection),
    # while the rest is random discretionary spend.
    paycheck = _money(rng, 2600, 3200)
    subscriptions = rng.sample(_SUBSCRIPTIONS, 2)
    transactions: list[SeedTransaction] = []
    for month in range(3):
        base = month * 30
        transactions.append(SeedTransaction(
            owner, f"{owner}:checking", "PAYROLL DIR DEP", -paycheck,
            currency, days_ago(base + 1), "Income"))
        for offset, (merchant, amount) in zip((7, 20), subscriptions):
            transactions.append(SeedTransaction(
                owner, f"{owner}:credit", merchant, amount, currency,
                days_ago(base + offset), "Subscriptions"))
    # Discretionary spend uses DISTINCT merchants (sampled without replacement) spread over the window, so no
    # non-subscription merchant ever repeats 3x - only the fixed monthly subscriptions above read as recurring
    # to the on-device detector (keeps the demo Inbox free of "Track Costco" style false positives).
    disc_pool = [(cat, m) for cat, ((_lo, _hi), ms) in _BANK_SPEND.items() for m in ms]
    picks = rng.sample(disc_pool, min(len(disc_pool), 15))
    for i, (category, merchant) in enumerate(picks):
        (lo, hi), _ = _BANK_SPEND[category]
        day = 2 + (i * 86) // max(len(picks) - 1, 1)
        transactions.append(SeedTransaction(
            owner, rng.choice([f"{owner}:checking", f"{owner}:credit"]),
            merchant, _money(rng, lo, hi), currency, days_ago(day), category))
    goals = [
        SeedGoal(kind="spend", owner=owner, name="Groceries budget", category="Groceries",
                 target_amount=Decimal("600")),
        SeedGoal(kind="save", owner=owner, name="Savings cushion", account_key=f"{owner}:savings",
                 target_amount=(savings_balance + Decimal("3000")).quantize(Decimal("1")),
                 save_target_type="balance", starting_balance=savings_balance),
    ]
    return accounts, transactions, goals


def _demo_layer(guest: str, apt_members: list[str],
                partner_rng: random.Random, today: date, currency: str):
    """Guest-only enrichment stitched into SeedData: expense↔transaction links, recategorizations + a
    taxonomy, a connected partner sharing two read-only accounts, and a couple pending transactions."""
    def days_ago(n: int) -> date:
        return today - timedelta(days=n)

    chk, crd = f"{guest}:checking", f"{guest}:credit"

    # 1) Linkable pairs: a self-hosted expense the guest paid, mirrored by a bank transaction, then linked.
    link_specs = [
        ("Groceries", "WHOLEFDS MKT #10234", Decimal("84.20"), 6),
        ("Dining", "SQ *SWEETGREEN", Decimal("52.75"), 11),
        ("Utilities", "COMCAST XFINITY 800-934", Decimal("96.40"), 15),
    ]
    link_expenses: list[SeedExpense] = []
    guest_txns: list[SeedTransaction] = []
    links: list[tuple[str, str]] = []
    for i, (cat, merchant, amount, ago) in enumerate(link_specs):
        ek, tk = f"lk-exp-{i}", f"lk-txn-{i}"
        link_expenses.append(SeedExpense(
            description=merchant, amount=amount, currency=currency, date=days_ago(ago),
            category=cat, created_by=guest, splits=_splits(amount, apt_members, guest), key=ek))
        guest_txns.append(SeedTransaction(guest, chk, merchant, amount, currency, days_ago(ago), cat, key=tk))
        links.append((ek, tk))

    # 2) Recategorizations: an explicit user override + an AI refinement of a vague ("Other") row.
    guest_txns += [
        SeedTransaction(guest, crd, "AMZN Mktp US*2Z9QT", Decimal("43.18"), currency,
                        days_ago(4), "Shopping", key="rc-explicit"),
        SeedTransaction(guest, chk, "SQ *BLUE BOTTLE", Decimal("6.75"), currency,
                        days_ago(2), "Other", key="rc-refined"),
    ]
    overrides = [
        SeedOverride("rc-explicit", category="Household", note="Cleaning supplies"),
        SeedOverride("rc-refined", refined_category="Dining"),
    ]

    # 3) Pending (not-yet-posted) transactions for variety.
    guest_txns += [
        SeedTransaction(guest, chk, "WHOLEFDS MKT #10234", Decimal("61.30"), currency,
                        days_ago(0), "Groceries", pending=True),
        SeedTransaction(guest, crd, "SHELL OIL 57442136", Decimal("41.90"), currency,
                        days_ago(1), "Fuel", pending=True),
    ]

    # 3b) UNLINKED look-alike pairs -> Inbox "link" (de-dupe) suggestions: a shared expense the guest paid and
    # its matching bank charge, same amount + same day but deliberately NOT linked, so the matcher surfaces them
    # (an exact same-day amount match scores ~0.90, over the 0.85 floor). Local merchants used once each, so
    # they never look recurring.
    unlinked_specs = [
        ("Dining", "Ramen Nagi", "TST* RAMEN NAGI 0421", Decimal("58.40"), 8),
        ("Household", "Ace Hardware", "ACE HARDWARE #6621", Decimal("41.20"), 14),
    ]
    for i, (cat, exp_name, txn_name, amount, ago) in enumerate(unlinked_specs):
        link_expenses.append(SeedExpense(
            description=exp_name, amount=amount, currency=currency, date=days_ago(ago),
            category=cat, created_by=guest, splits=_splits(amount, apt_members, guest)))  # no key -> unlinked
        guest_txns.append(SeedTransaction(guest, chk, txn_name, amount, currency, days_ago(ago), cat))

    # 3c) Categorize "Your rule" demo: Target charges carry Plaid's coarse GENERAL_MERCHANDISE label (resolves
    # deterministically to Shopping); the seeded merchant rule (see seeder) recategorizes Target to Household,
    # surfacing an Inbox "Your rule" categorize card. Two same-merchant rows aggregate into one "· 2" card.
    guest_txns += [
        SeedTransaction(guest, crd, "TARGET 00023456", Decimal("48.20"), currency,
                        days_ago(5), "GENERAL_MERCHANDISE"),
        SeedTransaction(guest, crd, "TARGET 00023456", Decimal("31.75"), currency,
                        days_ago(18), "GENERAL_MERCHANDISE"),
    ]

    # 4) A couple raw→canonical maps (taxonomy itself is CATEGORIES, set on SeedData).
    category_maps = [
        SeedCategoryMap("COFFEE SHOP", "Dining", "ondevice"),
        SeedCategoryMap("RIDESHARE", "Transport", "manual"),
    ]

    # 5) Connected partner sharing two read-only accounts (one full, one balances-only).
    partner = SeedUser(identifier=f"{guest}-partner", display_name="Jamie", source="manual",
                       avatar="jamie.png")
    p_accounts, p_txns, _goals = _finances(partner.identifier, partner_rng, today, currency)
    # Distinct names + banks so the shared accounts read clearly as Jamie's, not duplicates of the guest's.
    p_accounts[0].share_level = "full"       # checking: balance + transactions
    p_accounts[0].name = "Jamie's Checking"
    p_accounts[0].institution_name, p_accounts[0].institution_domain = "Capital One", "capitalone.com"
    p_accounts[2].share_level = "balances"   # savings: balance only
    p_accounts[2].name = "Jamie's Savings"
    p_accounts[2].institution_name, p_accounts[2].institution_domain = "Wells Fargo", "wellsfargo.com"
    connections = [(guest, partner.identifier)]

    return (link_expenses, guest_txns, links, overrides, category_maps,
            partner, p_accounts, p_txns, connections)


def generate(self_identifier: str = "alice", *, seed: int = 1234,
             today: date | None = None, currency: str = "USD") -> SeedData:
    """Deterministic for a given (self_identifier, seed, today)."""
    rng = random.Random(seed)
    today = today or date.today()

    you = SeedUser(identifier=self_identifier,
                   display_name=self_identifier.capitalize(), source="app")
    roommate = SeedUser(identifier=_PEOPLE[0].lower(), display_name=_PEOPLE[0])
    friends = [SeedUser(identifier=p.lower(), display_name=p) for p in _PEOPLE[1:3]]
    users = [you, roommate, *friends]

    def days_ago(n: int) -> date:
        return today - timedelta(days=n)

    # Apartment: you + one roommate. Curated distinct merchants so no everyday store recurs 3x monthly (which
    # the on-device detector would misread as a subscription). Rent appears twice (still < the 3-charge bar);
    # everything else once. (category, merchant, days_ago, itemized)
    apt_members = [you.identifier, roommate.identifier]
    apt_specs = [
        ("Rent", "Monthly Rent", 2, False),
        ("Groceries", "Whole Foods Market", 5, True),
        ("Dining", "Shake Shack", 9, False),
        ("Household", "The Home Depot", 14, False),
        ("Groceries", "Trader Joe's", 21, True),
        ("Entertainment", "AMC Theatres", 26, False),
        ("Rent", "Monthly Rent", 32, False),
        ("Dining", "Panera Bread", 38, False),
        ("Utilities", "Xfinity", 45, False),
        ("Groceries", "Safeway", 52, True),
        ("Household", "IKEA", 63, False),
        ("Dining", "Chipotle", 71, False),
        ("Groceries", "Costco Wholesale", 84, True),
    ]
    apt_expenses: list[SeedExpense] = [
        _expense(rng, cat, apt_members, days_ago(ago), currency, itemized, merchant=m)
        for cat, m, ago, itemized in apt_specs
    ]

    # Trip: you + two friends, a cluster of expenses on one recent week.
    trip_members = [you.identifier] + [f.identifier for f in friends]
    trip_start = 18
    trip_expenses = [
        _expense(rng, "Travel", trip_members, days_ago(trip_start), currency, False),
        _expense(rng, "Travel", trip_members, days_ago(trip_start), currency, False),
        _expense(rng, "Dining", trip_members, days_ago(trip_start - 1), currency, False),
        _expense(rng, "Fuel", trip_members, days_ago(trip_start - 1), currency, False),
        _expense(rng, "Entertainment", trip_members, days_ago(trip_start - 2), currency, False),
        _expense(rng, "Dining", trip_members, days_ago(trip_start - 2), currency, False),
        _expense(rng, "Transport", trip_members, days_ago(trip_start - 3), currency, False),
    ]

    # Guest-only enrichment (links, recategorizations, a connected partner, pending txns). Built before the
    # groups list so the linkable expenses join the Apartment group the guest is a member of.
    (link_expenses, guest_extra_txns, links, overrides, category_maps,
     partner, partner_accounts, partner_txns, connections) = _demo_layer(
        you.identifier, apt_members,
        random.Random(f"{seed}-{you.identifier}-partner"), today, currency)
    apt_expenses += link_expenses

    groups = [
        SeedGroup(name="Apartment", group_type="apartment", members=apt_members, expenses=apt_expenses,
                  avatar="apartment.png"),
        SeedGroup(name="Weekend Trip", group_type="trip", members=trip_members, expenses=trip_expenses,
                  avatar="weekend_trip.png"),
    ]

    # Personal finances for EVERY persona (so each impersonation token lands in a populated app): a few
    # accounts, ~3 months of bank transactions, and two goals - each owned by that user. A per-user RNG
    # keeps it deterministic but varied.
    accounts: list[SeedAccount] = []
    transactions: list[SeedTransaction] = []
    goals: list[SeedGoal] = []
    for u in users:
        a, t, g = _finances(u.identifier, random.Random(f"{seed}-{u.identifier}"), today, currency)
        accounts += a
        transactions += t
        goals += g

    # Fold in the enrichment: the guest's extra (linkable/recat/pending) transactions + the partner's
    # accounts/transactions (owned by `<guest>-partner`, shared read-only to the guest).
    transactions += guest_extra_txns + partner_txns
    accounts += partner_accounts

    return SeedData(users=users, groups=groups, accounts=accounts,
                    transactions=transactions, goals=goals,
                    partner=partner, connections=connections,
                    category_names=list(CATEGORIES), category_maps=category_maps,
                    overrides=overrides, links=links)
