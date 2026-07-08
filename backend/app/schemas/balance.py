from decimal import Decimal

from pydantic import BaseModel


class BalanceEntry(BaseModel):
    identifier: str
    display_name: str | None
    paid_total: Decimal
    owed_total: Decimal
    net: Decimal  # net > 0 => owed to this person; net < 0 => this person owes


class FriendGroupBalance(BaseModel):
    splitwise_group_id: str
    name: str | None  # local group name when the group is cached, else None
    net: Decimal  # the caller's net with the friend in this group; net > 0 => the friend owes the caller


class FriendBalance(BaseModel):
    identifier: str
    display_name: str | None
    net: Decimal  # the caller's pairwise net with this person; net > 0 => this person owes the caller
    groups: list[FriendGroupBalance] = []  # per shared group breakdown (Splitwise-sourced)
