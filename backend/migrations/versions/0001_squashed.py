"""squashed baseline: full schema as of 0061_account_merge

Collapses the original 61-migration chain (0001..0061) into a single fresh-install baseline: the complete
schema at head plus the two seed sets that persist to head (the brand_overrides merchant catalog and the
server_settings defaults). Data backfills and net-dropped tables from the old chain are intentionally
omitted; a fresh install has nothing to backfill. Databases already at 0061 are moved onto this baseline
with `alembic stamp --purge 0001_squashed` (schema already matches, so no DDL runs).

Revision ID: 0001_squashed
Revises:
Create Date: 2026-07-08
"""
import json
import os
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

import app.security.crypto

revision: str = "0001_squashed"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Enum types are created once, up front, so a type shared by several tables (transaction_source is used by
# both accounts and transactions) is not emitted twice. Columns reference them with create_type=False.
_ENUMS = (
    postgresql.ENUM("self_hosted", "splitwise", name="backend_type"),
    postgresql.ENUM("plaid", "manual", "simplefin", name="transaction_source"),
    postgresql.ENUM("app", "manual", "splitwise", name="user_source"),
    postgresql.ENUM("splitwise", "app", name="notification_source"),
    postgresql.ENUM("pending", "accepted", name="connection_status"),
    postgresql.ENUM("private", "balances", "full", name="share_level"),
)

# server_settings rows that exist at head 0061 (net of the old chain's seeds). The 7 policy keys mirror
# 0030's env-derived defaults so a self-hoster's env is honored at first migrate; the 3 threshold/retention
# keys were seeded as static literals by 0031/0032. Absent keys fall back to app/server_settings.REGISTRY.
_SETTINGS: dict[str, tuple[str | None, str, object]] = {
    "invites_open_to_members": (None, "bool", False),
    "public_hostname": ("PUBLIC_HOSTNAME", "str", ""),
    "splitwise_receipt_download_enabled": ("SPLITWISE_RECEIPT_DOWNLOAD_ENABLED", "bool", False),
    "sync_interval_hours": ("SYNC_INTERVAL_HOURS", "int", 0),
    "backup_interval_hours": ("BACKUP_INTERVAL_HOURS", "int", 0),
    "backups_retention_days": ("BACKUPS_RETENTION_DAYS", "int", 30),
    "backups_retention_min_keep": ("BACKUPS_RETENTION_MIN_KEEP", "int", 7),
    "notifications_retention_count": (None, "int", 100),
    "refresh_plaid_stale_minutes": (None, "int", 60),
    "refresh_splitwise_stale_minutes": (None, "int", 15),
}


def _env_value(env: str | None, kind: str, default: object) -> object:
    raw = os.getenv(env) if env else None
    if raw is None or raw == "":
        return default
    if kind == "bool":
        return raw.strip().lower() in {"1", "true", "yes", "on"}
    if kind == "int":
        try:
            return int(raw)
        except ValueError:
            return default
    return raw


def upgrade() -> None:
    bind = op.get_bind()
    for enum in _ENUMS:
        enum.create(bind, checkfirst=True)

    op.create_table('brand_overrides',
    sa.Column('pattern', sa.String(length=64), nullable=False),
    sa.Column('name', sa.String(length=120), nullable=False),
    sa.Column('domain', sa.String(length=255), server_default=sa.text("''::character varying"), nullable=False),
    sa.Column('position', sa.Integer(), server_default=sa.text("0"), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('pattern')
    )
    op.create_table('category_maps',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('raw_category', sa.String(length=128), nullable=False),
    sa.Column('canonical_category', sa.String(length=64), nullable=False),
    sa.Column('source', sa.String(length=16), server_default=sa.text("'manual'::character varying"), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'raw_category', name='uq_category_maps_owner_raw')
    )
    op.create_table('connections',
    sa.Column('requester_identifier', sa.String(length=128), nullable=False),
    sa.Column('addressee_identifier', sa.String(length=128), nullable=False),
    sa.Column('status', postgresql.ENUM('pending', 'accepted', name='connection_status', create_type=False), server_default=sa.text("'pending'::public.connection_status"), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('requester_identifier', 'addressee_identifier', name='uq_connection_pair')
    )
    op.create_table('device_tokens',
    sa.Column('user_identifier', sa.String(length=128), nullable=False),
    sa.Column('token', sa.String(length=256), nullable=False),
    sa.Column('platform', sa.String(length=16), server_default=sa.text("'ios'::character varying"), nullable=False),
    sa.Column('public_key', sa.String(length=128), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('user_identifier', 'token', name='uq_device_token')
    )
    op.create_table('friends',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('splitwise_friend_id', sa.String(length=64), nullable=False),
    sa.Column('identifier', sa.String(length=128), nullable=True),
    sa.Column('first_name', sa.String(length=255), nullable=True),
    sa.Column('last_name', sa.String(length=255), nullable=True),
    sa.Column('email', sa.String(length=255), nullable=True),
    sa.Column('avatar_url', sa.String(length=512), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'splitwise_friend_id', name='uq_friends_owner_friend')
    )
    op.create_table('groups',
    sa.Column('name', sa.String(length=255), nullable=False),
    sa.Column('backend_type', postgresql.ENUM('self_hosted', 'splitwise', name='backend_type', create_type=False), nullable=False),
    sa.Column('splitwise_group_id', sa.String(length=64), nullable=True),
    sa.Column('group_type', sa.String(length=32), nullable=True),
    sa.Column('avatar_url', sa.String(length=512), nullable=True),
    sa.Column('cover_photo_url', sa.String(length=512), nullable=True),
    sa.Column('avatar_object_key', sa.String(length=512), nullable=True),
    sa.Column('avatar_original_key', sa.String(length=512), nullable=True),
    sa.Column('avatar_content_type', sa.String(length=128), nullable=True),
    sa.Column('avatar_crop', sa.JSON(), nullable=True),
    sa.Column('superseded_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('invites',
    sa.Column('code', sa.String(length=64), nullable=False),
    sa.Column('created_by', sa.String(length=128), nullable=False),
    sa.Column('label', sa.String(length=255), nullable=True),
    sa.Column('expires_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('revoked_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('redeemed_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('redeemed_by', sa.String(length=128), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('notification_mutes',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('token', sa.String(length=80), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'token', name='uq_notification_mutes_owner_token')
    )
    op.create_table('notifications',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('source', postgresql.ENUM('splitwise', 'app', name='notification_source', create_type=False), nullable=False),
    sa.Column('splitwise_id', sa.String(length=64), nullable=True),
    sa.Column('type', sa.String(length=32), nullable=True),
    sa.Column('content', sa.Text(), nullable=False),
    sa.Column('entity_type', sa.String(length=32), nullable=True),
    sa.Column('entity_id', sa.String(length=128), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('read', sa.Boolean(), server_default=sa.text("false"), nullable=False),
    sa.Column('hidden', sa.Boolean(), server_default=sa.text('false'), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('plaid_items',
    sa.Column('plaid_item_id', sa.String(length=128), nullable=False),
    sa.Column('access_token', app.security.crypto.EncryptedString(), nullable=False),
    sa.Column('institution_name', sa.String(length=255), nullable=True),
    sa.Column('institution_id', sa.String(length=64), nullable=True),
    sa.Column('institution_domain', sa.String(length=255), nullable=True),
    sa.Column('institution_color', sa.String(length=16), nullable=True),
    sa.Column('institution_status', sa.String(length=32), nullable=True),
    sa.Column('transactions_cursor', sa.Text(), nullable=True),
    sa.Column('user_identifier', sa.String(length=128), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('plaid_item_id', name='uq_plaid_items_plaid_item_id')
    )
    op.create_table('server_settings',
    sa.Column('key', sa.String(length=64), nullable=False),
    sa.Column('value', sa.Text(), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('key')
    )
    op.create_table('simplefin_connections',
    sa.Column('access_url', app.security.crypto.EncryptedString(), nullable=False),
    sa.Column('status', sa.String(length=32), nullable=True),
    sa.Column('error', sa.String(length=512), nullable=True),
    sa.Column('last_synced_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('user_identifier', sa.String(length=128), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('spend_categories',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('name', sa.String(length=64), nullable=False),
    sa.Column('builtin', sa.Boolean(), server_default=sa.text("false"), nullable=False),
    sa.Column('position', sa.Integer(), server_default=sa.text("0"), nullable=False),
    sa.Column('icon', sa.String(length=64), nullable=True),
    sa.Column('color', sa.String(length=32), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'name', name='uq_spend_categories_owner_name')
    )
    op.create_table('splitwise_oauth_states',
    sa.Column('state', sa.String(length=128), nullable=False),
    sa.Column('code_verifier', sa.String(length=128), nullable=False),
    sa.Column('user_identifier', sa.String(length=128), nullable=False),
    sa.Column('invite', sa.String(length=64), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('state')
    )
    op.create_table('splitwise_tokens',
    sa.Column('user_identifier', sa.String(length=128), nullable=False),
    sa.Column('access_token', app.security.crypto.EncryptedString(), nullable=False),
    sa.Column('token_type', sa.String(length=32), server_default=sa.text("'bearer'::character varying"), nullable=False),
    sa.Column('scope', sa.String(length=256), nullable=True),
    sa.Column('expenses_synced_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('notifications_pushed_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('user_identifier', name='uq_splitwise_tokens_user_identifier')
    )
    op.create_table('user_preferences',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('key', sa.String(length=64), nullable=False),
    sa.Column('value', sa.Text(), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'key', name='uq_user_preferences_owner_key')
    )
    op.create_table('users',
    sa.Column('identifier', sa.String(length=128), nullable=False),
    sa.Column('display_name', sa.String(length=255), nullable=False),
    sa.Column('source', postgresql.ENUM('app', 'manual', 'splitwise', name='user_source', create_type=False), nullable=False),
    sa.Column('splitwise_user_id', sa.String(length=64), nullable=True),
    sa.Column('email', sa.String(length=255), nullable=True),
    sa.Column('registration_status', sa.String(length=32), nullable=True),
    sa.Column('apple_sub', sa.String(length=255), nullable=True),
    sa.Column('google_sub', sa.String(length=255), nullable=True),
    sa.Column('avatar_url', sa.String(length=512), nullable=True),
    sa.Column('avatar_object_key', sa.String(length=512), nullable=True),
    sa.Column('avatar_original_key', sa.String(length=512), nullable=True),
    sa.Column('avatar_content_type', sa.String(length=128), nullable=True),
    sa.Column('avatar_crop', sa.JSON(), nullable=True),
    sa.Column('enrolled', sa.Boolean(), nullable=False),
    sa.Column('is_admin', sa.Boolean(), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('apple_sub', name='uq_users_apple_sub'),
    sa.UniqueConstraint('google_sub', name='uq_users_google_sub'),
    sa.UniqueConstraint('identifier', name='uq_users_identifier')
    )
    op.create_table('accounts',
    sa.Column('name', sa.String(length=255), nullable=False),
    sa.Column('type', sa.String(length=64), nullable=True),
    sa.Column('mask', sa.String(length=32), nullable=True),
    sa.Column('plaid_account_id', sa.String(length=128), nullable=True),
    sa.Column('plaid_item_id', sa.UUID(), nullable=True),
    sa.Column('simplefin_account_id', sa.String(length=128), nullable=True),
    sa.Column('simplefin_connection_id', sa.UUID(), nullable=True),
    sa.Column('balance', sa.Numeric(precision=12, scale=2), server_default=sa.text("'0'::numeric"), nullable=False),
    sa.Column('available_balance', sa.Numeric(precision=12, scale=2), nullable=True),
    sa.Column('currency', sa.String(length=3), server_default=sa.text("'USD'::character varying"), nullable=False),
    sa.Column('external_account_id', sa.String(length=128), nullable=True),
    sa.Column('balance_as_of', sa.Date(), nullable=True),
    sa.Column('owner_identifier', sa.String(length=128), nullable=True),
    sa.Column('share_level', postgresql.ENUM('private', 'balances', 'full', name='share_level', create_type=False), server_default=sa.text("'private'::public.share_level"), nullable=False),
    sa.Column('institution_name', sa.String(length=255), nullable=True),
    sa.Column('institution_domain', sa.String(length=255), nullable=True),
    sa.Column('institution_color', sa.String(length=16), nullable=True),
    sa.Column('institution_status', sa.String(length=32), nullable=True),
    sa.Column('primary_source', postgresql.ENUM('plaid', 'manual', 'simplefin', name='transaction_source', create_type=False), nullable=True),
    sa.Column('merged_from_date', sa.Date(), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['plaid_item_id'], ['plaid_items.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['simplefin_connection_id'], ['simplefin_connections.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('plaid_account_id', name='uq_accounts_plaid_account_id')
    )
    op.create_table('group_members',
    sa.Column('group_id', sa.UUID(), nullable=False),
    sa.Column('user_identifier', sa.String(length=128), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['group_id'], ['groups.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('group_id', 'user_identifier', name='uq_group_members_group_user')
    )
    op.create_table('group_overrides',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('group_id', sa.UUID(), nullable=False),
    sa.Column('hidden', sa.Boolean(), nullable=True),
    sa.Column('include_in_spending', sa.Boolean(), nullable=True),
    sa.Column('include_in_cash_flow', sa.Boolean(), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['group_id'], ['groups.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'group_id', name='uq_group_override_owner_group')
    )
    op.create_table('account_overrides',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('account_id', sa.UUID(), nullable=False),
    sa.Column('display_name', sa.String(length=255), nullable=True),
    sa.Column('kind', sa.String(length=16), nullable=True),
    sa.Column('include_in_spending', sa.Boolean(), nullable=True),
    sa.Column('include_in_cash_flow', sa.Boolean(), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['account_id'], ['accounts.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'account_id', name='uq_account_override_owner_account')
    )
    op.create_table('goals',
    sa.Column('kind', sa.String(length=16), nullable=False),
    sa.Column('name', sa.String(length=128), nullable=False),
    sa.Column('owner_identifier', sa.String(length=128), nullable=True),
    sa.Column('category', sa.String(length=64), nullable=True),
    sa.Column('account_id', sa.UUID(), nullable=True),
    sa.Column('target_amount', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('save_target_type', sa.String(length=16), nullable=True),
    sa.Column('starting_balance', sa.Numeric(precision=12, scale=2), nullable=True),
    sa.Column('starting_date', sa.Date(), nullable=True),
    sa.Column('period', sa.String(length=16), server_default=sa.text("'monthly'::character varying"), nullable=False),
    sa.Column('currency', sa.String(length=3), server_default=sa.text("'USD'::character varying"), nullable=False),
    sa.Column('archived_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('shared', sa.Boolean(), server_default=sa.text("false"), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['account_id'], ['accounts.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('transactions',
    sa.Column('account_id', sa.UUID(), nullable=True),
    sa.Column('plaid_transaction_id', sa.String(length=128), nullable=True),
    sa.Column('external_transaction_id', sa.String(length=128), nullable=True),
    sa.Column('pending_transaction_id', sa.String(length=128), nullable=True),
    sa.Column('source', postgresql.ENUM('plaid', 'manual', 'simplefin', name='transaction_source', create_type=False), nullable=False),
    sa.Column('description', sa.String(length=512), nullable=False),
    sa.Column('amount', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('currency', sa.String(length=3), server_default=sa.text("'USD'::character varying"), nullable=False),
    sa.Column('date', sa.Date(), nullable=False),
    sa.Column('category', sa.String(length=128), nullable=True),
    sa.Column('owner_identifier', sa.String(length=128), nullable=True),
    sa.Column('pending', sa.Boolean(), server_default=sa.text("false"), nullable=False),
    sa.Column('client_key', sa.String(length=64), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['account_id'], ['accounts.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('plaid_transaction_id', name='uq_transactions_plaid_transaction_id')
    )
    op.create_table('expenses',
    sa.Column('group_id', sa.UUID(), nullable=False),
    sa.Column('transaction_id', sa.UUID(), nullable=True),
    sa.Column('splitwise_expense_id', sa.String(length=64), nullable=True),
    sa.Column('client_key', sa.String(length=64), nullable=True),
    sa.Column('description', sa.String(length=512), nullable=False),
    sa.Column('amount', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('currency', sa.String(length=3), server_default=sa.text("'USD'::character varying"), nullable=False),
    sa.Column('date', sa.Date(), nullable=False),
    sa.Column('category', sa.String(length=128), nullable=True),
    sa.Column('created_by', sa.String(length=128), nullable=True),
    sa.Column('updated_by', sa.String(length=128), nullable=True),
    sa.Column('splitwise_created_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('splitwise_updated_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('comments_count', sa.Integer(), nullable=True),
    sa.Column('repeats', sa.Boolean(), nullable=True),
    sa.Column('repeat_interval', sa.String(length=32), nullable=True),
    sa.Column('expense_bundle_id', sa.String(length=64), nullable=True),
    sa.Column('splitwise_receipt_url', sa.String(length=512), nullable=True),
    sa.Column('repayments', postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['group_id'], ['groups.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['transaction_id'], ['transactions.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('splitwise_expense_id', name='uq_expenses_splitwise_expense_id')
    )
    op.create_table('goal_budget_notifications',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('goal_id', sa.UUID(), nullable=False),
    sa.Column('period_month', sa.Date(), nullable=False),
    sa.Column('kind', sa.String(length=16), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['goal_id'], ['goals.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('goal_id', 'period_month', 'kind', name='uq_goal_budget_notif')
    )
    op.create_table('transaction_items',
    sa.Column('transaction_id', sa.UUID(), nullable=False),
    sa.Column('name', sa.String(length=255), nullable=False),
    sa.Column('quantity', sa.Numeric(precision=10, scale=3), server_default=sa.text("'1'::numeric"), nullable=False),
    sa.Column('price', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('category', sa.String(length=128), nullable=True),
    sa.Column('created_by', sa.String(length=255), nullable=True),
    sa.Column('updated_by', sa.String(length=255), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['transaction_id'], ['transactions.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('transaction_overrides',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('transaction_id', sa.UUID(), nullable=False),
    sa.Column('category', sa.String(length=128), nullable=True),
    sa.Column('refined_category', sa.String(length=64), nullable=True),
    sa.Column('include_in_spending', sa.Boolean(), nullable=True),
    sa.Column('include_in_cash_flow', sa.Boolean(), nullable=True),
    sa.Column('note', sa.String(length=500), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['transaction_id'], ['transactions.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'transaction_id', name='uq_txn_override_owner_txn')
    )
    op.create_table('expense_items',
    sa.Column('expense_id', sa.UUID(), nullable=False),
    sa.Column('name', sa.String(length=255), nullable=False),
    sa.Column('quantity', sa.Numeric(precision=10, scale=3), server_default=sa.text("'1'::numeric"), nullable=False),
    sa.Column('price', sa.Numeric(precision=12, scale=2), nullable=False),
    sa.Column('category', sa.String(length=128), nullable=True),
    sa.Column('owner_identifier', sa.String(length=255), nullable=True),
    sa.Column('created_by', sa.String(length=255), nullable=True),
    sa.Column('updated_by', sa.String(length=255), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['expense_id'], ['expenses.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('expense_overrides',
    sa.Column('owner_identifier', sa.String(length=128), nullable=False),
    sa.Column('expense_id', sa.UUID(), nullable=False),
    sa.Column('include_in_spending', sa.Boolean(), nullable=True),
    sa.Column('include_in_cash_flow', sa.Boolean(), nullable=True),
    sa.Column('note', sa.String(length=500), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['expense_id'], ['expenses.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('owner_identifier', 'expense_id', name='uq_expense_override_owner_expense')
    )
    op.create_table('receipts',
    sa.Column('expense_id', sa.UUID(), nullable=True),
    sa.Column('transaction_id', sa.UUID(), nullable=True),
    sa.Column('bucket', sa.String(length=128), nullable=False),
    sa.Column('object_key', sa.String(length=512), nullable=False),
    sa.Column('content_type', sa.String(length=128), nullable=True),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.CheckConstraint('(expense_id IS NULL) <> (transaction_id IS NULL)', name='receipts_expense_xor_transaction'),
    sa.ForeignKeyConstraint(['expense_id'], ['expenses.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['transaction_id'], ['transactions.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_table('splits',
    sa.Column('expense_id', sa.UUID(), nullable=False),
    sa.Column('user_identifier', sa.String(length=128), nullable=False),
    sa.Column('paid_share', sa.Numeric(precision=12, scale=2), server_default=sa.text("'0'::numeric"), nullable=False),
    sa.Column('owed_share', sa.Numeric(precision=12, scale=2), server_default=sa.text("'0'::numeric"), nullable=False),
    sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['expense_id'], ['expenses.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    

    # --- indexes (names match the original chain, so a stamped 0061 database already matches) ---
    op.create_index("ix_account_override_account", "account_overrides", ["account_id"])
    op.create_index("ix_account_override_owner", "account_overrides", ["owner_identifier"])
    op.create_index("ix_category_maps_owner", "category_maps", ["owner_identifier"])
    op.create_index("ix_connections_addressee", "connections", ["addressee_identifier"])
    op.create_index("ix_connections_requester", "connections", ["requester_identifier"])
    op.create_index("ix_device_tokens_user", "device_tokens", ["user_identifier"])
    op.create_index("ix_expense_override_expense", "expense_overrides", ["expense_id"])
    op.create_index("ix_expense_override_owner", "expense_overrides", ["owner_identifier"])
    op.create_index("ix_goal_budget_notif_goal", "goal_budget_notifications", ["goal_id"])
    op.create_index("ix_goal_budget_notif_owner", "goal_budget_notifications", ["owner_identifier"])
    op.create_index("ix_group_override_group", "group_overrides", ["group_id"])
    op.create_index("ix_group_override_owner", "group_overrides", ["owner_identifier"])
    op.create_index("ix_notification_mutes_owner_identifier", "notification_mutes", ["owner_identifier"])
    op.create_index("ix_simplefin_connections_user", "simplefin_connections", ["user_identifier"])
    op.create_index("ix_spend_categories_owner", "spend_categories", ["owner_identifier"])
    op.create_index("ix_transactions_pending_transaction_id", "transactions", ["pending_transaction_id"])
    op.create_index("ix_txn_override_owner", "transaction_overrides", ["owner_identifier"])
    op.create_index("ix_txn_override_transaction", "transaction_overrides", ["transaction_id"])
    op.create_index("ix_user_preferences_owner_identifier", "user_preferences", ["owner_identifier"])
    op.create_index("ix_invites_code", "invites", ["code"], unique=True)
    op.create_index("uq_account_owner_external", "accounts", ["owner_identifier", "external_account_id"], unique=True, postgresql_where=sa.text("external_account_id IS NOT NULL"))
    op.create_index("uq_account_simplefin", "accounts", ["simplefin_connection_id", "simplefin_account_id"], unique=True, postgresql_where=sa.text("simplefin_connection_id IS NOT NULL"))
    op.create_index("uq_expense_creator_client_key", "expenses", ["created_by", "client_key"], unique=True, postgresql_where=sa.text("client_key IS NOT NULL"))
    op.create_index("uq_groups_splitwise_group_id", "groups", ["splitwise_group_id"], unique=True, postgresql_where=sa.text("splitwise_group_id IS NOT NULL"))
    op.create_index("uq_notifications_owner_source_swid", "notifications", ["owner_identifier", "source", "splitwise_id"], unique=True, postgresql_where=sa.text("splitwise_id IS NOT NULL"))
    op.create_index("uq_txn_account_external", "transactions", ["account_id", "external_transaction_id"], unique=True, postgresql_where=sa.text("external_transaction_id IS NOT NULL"))
    op.create_index("uq_txn_owner_client_key", "transactions", ["owner_identifier", "client_key"], unique=True, postgresql_where=sa.text("client_key IS NOT NULL"))

    # --- seed: brand_overrides merchant catalog (63 rows; updated_at defaults) ---
    brand_overrides = sa.table(
        "brand_overrides",
        sa.column("pattern", sa.String),
        sa.column("name", sa.String),
        sa.column("domain", sa.String),
        sa.column("position", sa.Integer),
    )
    op.bulk_insert(brand_overrides, [
        {"pattern": 'netflix', "name": 'Netflix', "domain": 'netflix.com', "position": 0},
        {"pattern": 'spotify', "name": 'Spotify', "domain": 'spotify.com', "position": 1},
        {"pattern": 'hulu', "name": 'Hulu', "domain": 'hulu.com', "position": 2},
        {"pattern": 'disney', "name": 'Disney+', "domain": 'disneyplus.com', "position": 3},
        {"pattern": 'hbo', "name": 'Max', "domain": 'max.com', "position": 4},
        {"pattern": 'youtube', "name": 'YouTube', "domain": 'youtube.com', "position": 5},
        {"pattern": 'audible', "name": 'Audible', "domain": 'audible.com', "position": 6},
        {"pattern": 'amazon', "name": 'Amazon', "domain": 'amazon.com', "position": 7},
        {"pattern": 'prime', "name": 'Amazon Prime', "domain": 'amazon.com', "position": 8},
        {"pattern": 'adobe', "name": 'Adobe', "domain": 'adobe.com', "position": 9},
        {"pattern": 'dropbox', "name": 'Dropbox', "domain": 'dropbox.com', "position": 10},
        {"pattern": 'microsoft', "name": 'Microsoft', "domain": 'microsoft.com', "position": 11},
        {"pattern": 'xbox', "name": 'Xbox', "domain": 'xbox.com', "position": 12},
        {"pattern": 'playstation', "name": 'PlayStation', "domain": 'playstation.com', "position": 13},
        {"pattern": 'nintendo', "name": 'Nintendo', "domain": 'nintendo.com', "position": 14},
        {"pattern": 'paramount', "name": 'Paramount+', "domain": 'paramountplus.com', "position": 15},
        {"pattern": 'peacock', "name": 'Peacock', "domain": 'peacocktv.com', "position": 16},
        {"pattern": 'espn', "name": 'ESPN+', "domain": 'espn.com', "position": 17},
        {"pattern": 'crunchyroll', "name": 'Crunchyroll', "domain": 'crunchyroll.com', "position": 18},
        {"pattern": 'twitch', "name": 'Twitch', "domain": 'twitch.tv', "position": 19},
        {"pattern": 'patreon', "name": 'Patreon', "domain": 'patreon.com', "position": 20},
        {"pattern": 'github', "name": 'GitHub', "domain": 'github.com', "position": 21},
        {"pattern": 'notion', "name": 'Notion', "domain": 'notion.so', "position": 22},
        {"pattern": 'openai', "name": 'OpenAI', "domain": 'openai.com', "position": 23},  # ai-tells:ignore
        {"pattern": 'chatgpt', "name": 'ChatGPT', "domain": 'openai.com', "position": 24},  # ai-tells:ignore
        {"pattern": 'anthropic', "name": 'Claude', "domain": 'claude.ai', "position": 25},  # ai-tells:ignore
        {"pattern": 'claude', "name": 'Claude', "domain": 'claude.ai', "position": 26},  # ai-tells:ignore
        {"pattern": 'peloton', "name": 'Peloton', "domain": 'onepeloton.com', "position": 27},
        {"pattern": 'slack', "name": 'Slack', "domain": 'slack.com', "position": 28},
        {"pattern": 'zoom', "name": 'Zoom', "domain": 'zoom.us', "position": 29},
        {"pattern": 'verizon', "name": 'Verizon', "domain": 'verizon.com', "position": 30},
        {"pattern": 'comcast', "name": 'Xfinity', "domain": 'xfinity.com', "position": 31},
        {"pattern": 'xfinity', "name": 'Xfinity', "domain": 'xfinity.com', "position": 32},
        {"pattern": 'apple', "name": 'Apple', "domain": 'apple.com', "position": 33},
        {"pattern": 'google', "name": 'Google', "domain": 'google.com', "position": 34},
        {"pattern": 'whole foods', "name": 'Whole Foods Market', "domain": 'wholefoodsmarket.com', "position": 100},
        {"pattern": 'trader joe', "name": "Trader Joe's", "domain": 'traderjoes.com', "position": 101},
        {"pattern": 'safeway', "name": 'Safeway', "domain": 'safeway.com', "position": 102},
        {"pattern": 'costco', "name": 'Costco', "domain": 'costco.com', "position": 103},
        {"pattern": 'chipotle', "name": 'Chipotle', "domain": 'chipotle.com', "position": 104},
        {"pattern": 'starbucks', "name": 'Starbucks', "domain": 'starbucks.com', "position": 105},
        {"pattern": 'blue bottle', "name": 'Blue Bottle Coffee', "domain": 'bluebottlecoffee.com', "position": 106},
        {"pattern": 'sweetgreen', "name": 'Sweetgreen', "domain": 'sweetgreen.com', "position": 107},
        {"pattern": 'shake shack', "name": 'Shake Shack', "domain": 'shakeshack.com', "position": 108},
        {"pattern": 'panera', "name": 'Panera Bread', "domain": 'panerabread.com', "position": 109},
        {"pattern": 'home depot', "name": 'The Home Depot', "domain": 'homedepot.com', "position": 110},
        {"pattern": 'ikea', "name": 'IKEA', "domain": 'ikea.com', "position": 111},
        {"pattern": 'target', "name": 'Target', "domain": 'target.com', "position": 112},
        {"pattern": 'best buy', "name": 'Best Buy', "domain": 'bestbuy.com', "position": 113},
        {"pattern": 'nike', "name": 'Nike', "domain": 'nike.com', "position": 114},
        {"pattern": 'shell', "name": 'Shell', "domain": 'shell.com', "position": 115},
        {"pattern": 'chevron', "name": 'Chevron', "domain": 'chevron.com', "position": 116},
        {"pattern": 'exxon', "name": 'Exxon', "domain": 'exxon.com', "position": 117},
        {"pattern": 'uber', "name": 'Uber', "domain": 'uber.com', "position": 118},
        {"pattern": 'lyft', "name": 'Lyft', "domain": 'lyft.com', "position": 119},
        {"pattern": 'delta air', "name": 'Delta Air Lines', "domain": 'delta.com', "position": 120},
        {"pattern": 'airbnb', "name": 'Airbnb', "domain": 'airbnb.com', "position": 121},
        {"pattern": 'marriott', "name": 'Marriott', "domain": 'marriott.com', "position": 122},
        {"pattern": '/\\bamc\\b/', "name": 'AMC Theatres', "domain": 'amctheatres.com', "position": 123},
        {"pattern": '/\\bsteam\\b/', "name": 'Steam', "domain": 'steampowered.com', "position": 124},
        {"pattern": 'wholefds', "name": 'Whole Foods Market', "domain": 'wholefoodsmarket.com', "position": 130},
        {"pattern": 'amzn', "name": 'Amazon', "domain": 'amazon.com', "position": 131},
        {"pattern": 'sbux', "name": 'Starbucks', "domain": 'starbucks.com', "position": 132},
    ])

    # --- seed: server_settings defaults (env-derived where the old chain read env) ---
    server_settings = sa.table(
        "server_settings", sa.column("key", sa.String), sa.column("value", sa.Text)
    )
    op.bulk_insert(server_settings, [
        {"key": key, "value": json.dumps(_env_value(env, kind, default))}
        for key, (env, kind, default) in _SETTINGS.items()
    ])


def downgrade() -> None:
    op.drop_index("ix_account_override_account", table_name="account_overrides")
    op.drop_index("ix_account_override_owner", table_name="account_overrides")
    op.drop_index("ix_category_maps_owner", table_name="category_maps")
    op.drop_index("ix_connections_addressee", table_name="connections")
    op.drop_index("ix_connections_requester", table_name="connections")
    op.drop_index("ix_device_tokens_user", table_name="device_tokens")
    op.drop_index("ix_expense_override_expense", table_name="expense_overrides")
    op.drop_index("ix_expense_override_owner", table_name="expense_overrides")
    op.drop_index("ix_goal_budget_notif_goal", table_name="goal_budget_notifications")
    op.drop_index("ix_goal_budget_notif_owner", table_name="goal_budget_notifications")
    op.drop_index("ix_group_override_group", table_name="group_overrides")
    op.drop_index("ix_group_override_owner", table_name="group_overrides")
    op.drop_index("ix_notification_mutes_owner_identifier", table_name="notification_mutes")
    op.drop_index("ix_simplefin_connections_user", table_name="simplefin_connections")
    op.drop_index("ix_spend_categories_owner", table_name="spend_categories")
    op.drop_index("ix_transactions_pending_transaction_id", table_name="transactions")
    op.drop_index("ix_txn_override_owner", table_name="transaction_overrides")
    op.drop_index("ix_txn_override_transaction", table_name="transaction_overrides")
    op.drop_index("ix_user_preferences_owner_identifier", table_name="user_preferences")
    op.drop_index("ix_invites_code", table_name="invites")
    op.drop_index("uq_account_owner_external", table_name="accounts")
    op.drop_index("uq_account_simplefin", table_name="accounts")
    op.drop_index("uq_expense_creator_client_key", table_name="expenses")
    op.drop_index("uq_groups_splitwise_group_id", table_name="groups")
    op.drop_index("uq_notifications_owner_source_swid", table_name="notifications")
    op.drop_index("uq_txn_account_external", table_name="transactions")
    op.drop_index("uq_txn_owner_client_key", table_name="transactions")
    op.drop_table("splits")
    op.drop_table("receipts")
    op.drop_table("expense_overrides")
    op.drop_table("expense_items")
    op.drop_table("transaction_overrides")
    op.drop_table("transaction_items")
    op.drop_table("goal_budget_notifications")
    op.drop_table("expenses")
    op.drop_table("transactions")
    op.drop_table("goals")
    op.drop_table("account_overrides")
    op.drop_table("group_overrides")
    op.drop_table("group_members")
    op.drop_table("accounts")
    op.drop_table("users")
    op.drop_table("user_preferences")
    op.drop_table("splitwise_tokens")
    op.drop_table("splitwise_oauth_states")
    op.drop_table("spend_categories")
    op.drop_table("simplefin_connections")
    op.drop_table("server_settings")
    op.drop_table("plaid_items")
    op.drop_table("notifications")
    op.drop_table("notification_mutes")
    op.drop_table("invites")
    op.drop_table("groups")
    op.drop_table("friends")
    op.drop_table("device_tokens")
    op.drop_table("connections")
    op.drop_table("category_maps")
    op.drop_table("brand_overrides")
    for enum in _ENUMS:
        enum.drop(op.get_bind(), checkfirst=True)
