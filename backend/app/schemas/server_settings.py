from pydantic import BaseModel


class ServerSettingsResponse(BaseModel):
    """The full server-settings registry resolved to current values."""
    invites_open_to_members: bool
    public_hostname: str
    default_currency: str
    splitwise_receipt_download_enabled: bool
    splitwise_receipt_backfill_enabled: bool
    sync_interval_hours: int
    backup_interval_hours: int
    backups_retention_days: int
    backups_retention_min_keep: int
    offsite_backup_enabled: bool
    offsite_backup_target: str
    refresh_plaid_stale_minutes: int
    refresh_splitwise_stale_minutes: int
    refresh_simplefin_stale_minutes: int
    simplefin_enabled: bool
    plaid_enabled: bool
    notifications_retention_count: int
    notifications_poll_minutes: int
    push_enabled: bool
    budget_push_enabled: bool


class ServerSettingsUpdate(BaseModel):
    """Any subset of the registry; only provided keys change (PATCH semantics)."""
    invites_open_to_members: bool | None = None
    public_hostname: str | None = None
    default_currency: str | None = None
    splitwise_receipt_download_enabled: bool | None = None
    splitwise_receipt_backfill_enabled: bool | None = None
    sync_interval_hours: int | None = None
    backup_interval_hours: int | None = None
    backups_retention_days: int | None = None
    backups_retention_min_keep: int | None = None
    offsite_backup_enabled: bool | None = None
    offsite_backup_target: str | None = None
    refresh_plaid_stale_minutes: int | None = None
    refresh_splitwise_stale_minutes: int | None = None
    refresh_simplefin_stale_minutes: int | None = None
    simplefin_enabled: bool | None = None
    plaid_enabled: bool | None = None
    notifications_retention_count: int | None = None
    notifications_poll_minutes: int | None = None
    push_enabled: bool | None = None
    budget_push_enabled: bool | None = None
