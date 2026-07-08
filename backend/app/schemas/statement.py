from uuid import UUID

from pydantic import BaseModel


class StatementImportResult(BaseModel):
    account_id: UUID
    account_name: str
    imported: int  # new transactions added
    skipped: int   # already present (FITID dedup)
    total: int     # transactions in the statement
    # True when this card looks already linked via Plaid and nothing was imported (account_id/name = the matched
    # Plaid account). The client confirms, then re-imports with force=true to create the separate account anyway.
    plaid_conflict: bool = False
