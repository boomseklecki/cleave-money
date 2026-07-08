# Cleave - Project Plan

> The original design and vision doc, kept for history. The component READMEs are the current
> source of truth; some early details here (for example provider tiers) have since changed.

## Concept

A self-hosted, iOS-native personal finance + expense-splitting app. Originally pitched as a Splitwise clone ("dividewiser"), it evolved into a broader Mint-replacement: account balance/transaction sync, AI-powered receipt scanning, item-level expense detail, and Splitwise interoperability for groups that include people outside the household.

Core principle: **no double-entry**. Private expenses (Alice + Bob) live entirely on the self-hosted backend, full-featured and free. Shared expenses with outside friends route through the Splitwise API so those groups keep working normally.

## Key Features

- **On-device AI receipt scanning**: OCR via Vision/VisionKit, structured extraction (merchant, date, line items, category) via Apple's Foundation Models framework (`@Generable`), fully offline
- **Per-group backend routing**: each group is either `self-hosted` or `splitwise`-linked; expense model is provider-agnostic
- **Splitwise bridge**: OAuth2 + PKCE per-user auth, push expenses to shared Splitwise groups via their API
- **Account balance/transaction sync**: Plaid integration (the free Trial tier covers a personal setup), `/transactions/sync` for incremental pulls
- **Transaction-to-expense picker**: select a Plaid transaction, prefill an expense, assign splits
- **Item-level expense detail**: line items with name/qty/price/category, stored per expense
- **Receipt image storage**: self-hosted, linked to expenses
- **Future**: AI budgeting check-ins/insights (backend job over Postgres data)
- **Historical import**: pull existing Splitwise expense history via `getExpenses` API (no receipt photos available from Splitwise's API - known gap)

## Architecture

- **Backend**: Postgres + lightweight API service on existing home Docker server, exposed via Cloudflare tunnel
- **Sync model**: server is source of truth; iOS app caches locally (SwiftData/Core Data), syncs on reconnect
- **Plaid**: backend-only - stores access tokens, runs transaction sync, never touches the iOS app directly
- **Splitwise**: backend calls Splitwise API for shared-group expenses and historical import
- **Receipt storage**: MinIO (S3-compatible, self-hosted) alongside Postgres; receipt bytes are proxied through the API (upload/download) so the iOS app reaches only the one API host and never touches MinIO directly

## Database Schema (Postgres)

Core tables: `accounts` (Plaid-linked balances), `transactions` (Plaid + manual, unified), `expenses` (split-relevant records, `splitwise_expense_id` for sync/dedupe), `expense_items` (line-item detail), `splits` (per-person share), `receipts` (MinIO object references), `groups` (self-hosted vs. Splitwise-linked).

Dedup strategy: unique constraints on `transactions.plaid_transaction_id` and `expenses.splitwise_expense_id`.

## Splitwise Historical Import

1. OAuth2 against Splitwise, store access token
1. Paginate `getExpenses` per group, scoped by date range
1. Map to schema: description, amount, date, payer (from `paid_share`), category, `splitwise_expense_id` for dedupe, per-user `splits` from `owed_share`
1. Map each Splitwise group to a `groups` row with `backend_type='splitwise'`
1. Decide handling for settle-up/payment-only expenses (separate category vs. filter out)
1. No line items or receipt images available from API - known limitation

## Open / Next Steps

- Draft API endpoints (upload flow, sync flow, split logic)
- iOS data layer (SwiftData models mirroring Postgres schema)
- Category taxonomy mapping (affects both Splitwise import and AI categorization)
- Write Splitwise import script (Python `splitwise` package)
- Trademark/naming check - landed on **Cleave** (contranym: to split apart and to join together; domain cleave.money)

## Misc Notes

- Plaid is commercial but its free Trial tier covers a personal setup; SimpleFIN considered as a hobbyist-friendlier alternative
- Blockchain storage considered and rejected for both DB and receipts - Postgres + MinIO are simpler, faster, and sufficient at this scale
