# Cleave - Backlog

Single source of truth for open / deferred work (memory notes are fragmented; this is the consolidated view).
Effort: **XS** ≈ minutes · **S** ≈ <½ day · **M** ≈ a day or few · **L** ≈ multi-phase.
Keep it current: move done items out (git history is the record), add new ones as they come up.

## 🚢 Release / operational - mostly decisions, little/no code
| Item | Effort | Notes |
|---|---|---|
| Cut the TestFlight build | - | v1.0 readiness verified 6/6; nothing infra blocks it |
| Rotate default MinIO + Postgres credentials | S | The bundled compose ships dev-default credentials for local use. Before exposing an instance, set strong random values for the MinIO and Postgres secrets. They are baked into the volumes at init, so changing them is a credential change + careful re-init, not just an `.env` edit. |
| Activate the deploy workflow | S | `.github/workflows/deploy.yml` is committed but inert. To turn on GitHub Actions CD: install a self-hosted runner on the deploy server labelled `deploy`, and create the `deploy-approval` + `production` environments with required reviewers. GitHub-settings only, no code |

## 💡 Product - would need building
| Item | Effort | Notes |
|---|---|---|
| AI auto-apply categorize | S–M | Settings toggle + apply path so AI categories apply directly instead of routing through the Inbox. Self-contained iOS |
| Sub-categories (two-level taxonomy) | **L** | Cross-cutting: `SpendCategory` gains a parent (migration + backfill), resolver/provenance, budgets/goals roll-up, AI + Inbox `allowed` lists, Splitwise/Plaid mapping. Alcohol/Services shipped as flat increments; the real version is its own multi-phase effort |

## 🅿️ Parked (long-term / multi-tenant - revisit when relevant)
- Notification deep-linking (row → expense/group) + per-user notification preferences / mute.
- Hidden-group per-user declutter UI (the `group_overrides.hidden` column exists as a seed; no UI).
- More statement-import formats (CSV / QFX / QBO); on-device verification of the Apple Card `.ofx` Wallet share-sheet tag.
- Push relay hardening: SMTP-emailed keys, admin dashboard, persistent per-key quotas, splitting `relay/` into its own repo.
- Push-payload E2E encryption tightening (`RELAY_REQUIRE_E2EE`) - only at multi-tenant time.
- Sync link-sensitivity across devices; silent/background push; manual "remind to settle up".
