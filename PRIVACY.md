# Privacy Policy

_Last updated: 2026-07-08_

Cleave is a self-hosted personal-finance and expense-splitting system: an iOS app that talks to a
backend **you** (or whoever runs your instance) operate. Because of that, "who holds your data"
depends on how you use Cleave. This policy covers both cases:

1. **Self-hosted instances** you or someone else runs.
2. **Services the Cleave maintainers operate**: the public demo instance and the official push relay.

Throughout this document, "we", "us", and "the Cleave maintainers" refer to the maintainers of the
Cleave open-source project, who operate those two services. Contact: **privacy@cleave.money**.

> This document describes how the software handles data and how our operated services work. It is
> provided as a starting point and is not legal advice. If you operate a Cleave instance for other
> people, you are responsible for your own privacy obligations.

## 1. Self-hosted instances

When you run your own Cleave backend, **you are the data controller**. Your data lives on your own
server (Postgres and MinIO object storage) and on your own devices. The Cleave maintainers operate
nothing in that path, cannot see your instance, and have no access to your data.

**What a Cleave backend stores** (on your infrastructure):

- Accounts, transactions, balances, expenses, splits, groups, and budgets/goals you create or sync.
- Receipt and avatar images, in your MinIO object store.
- Authentication and provider access tokens (for example Plaid and Splitwise), **encrypted at rest**
  when you set an encryption key.
- Notifications, invites, and per-user settings.

**Third-party services you may connect.** Cleave can integrate with external providers, but only if
you configure them. When you do, data flows to those providers under their own terms, not ours:

- **Plaid** and **SimpleFIN** for bank/transaction sync.
- **Splitwise** for two-way group sync and history import.
- **Sign in with Apple** and **Sign in with Google** for authentication (the backend verifies the
  provider's token; it does not receive your provider password).

You choose whether to enable any of these. Review each provider's own privacy policy before connecting
it.

## 2. The iOS app

- The app talks **only to the backend you point it at**. It does not send your data to the Cleave
  maintainers.
- Analytics, categorization, receipt reading, and recurring-charge detection run **on your device**.
  The features that use Apple Intelligence use Apple's on-device models; your financial data is not
  uploaded for these.
- Your session token for each backend is stored in the device Keychain, keyed per server, and is never
  sent to a server that did not issue it.
- Push notifications are **end-to-end encrypted** (see the relay section below).

## 3. Services operated by the Cleave maintainers

### 3a. The demo instance (demo.cleave.money)

We run a public demo so people can try Cleave without setting up a server.

- The demo uses a name-only guest login and seeds sample data. It is for **evaluation only**.
- **Do not enter real financial information or real account credentials in the demo.** Anything you
  enter may be visible to other people using the demo and is **periodically wiped**.
- We do not use demo activity for advertising or profiling.

### 3b. The push relay (push.cleave.money)

Because the open-source backend holds no Apple push credentials, notifications for the App Store build
are forwarded through a relay we operate. When a backend registers with the relay, the relay stores:

- The **email address** and optional **instance name** submitted at registration, and the API key it
  issues to that backend.
- For each device that will receive push: a **device token** and a **public key**.

The relay forwards notifications to Apple's Push Notification service. **Notification payloads are
end-to-end encrypted**: the relay (and Apple) see only ciphertext and a generic placeholder such as
"New activity", never the contents of your notifications. Registration is rate-limited to prevent
abuse. We do not sell or share this data, and use it only to deliver push notifications.

## 4. What we do not do

Across the demo instance and the relay, the Cleave maintainers do **not** run third-party analytics or
advertising trackers, do **not** sell or rent your data, and do **not** build advertising profiles.

## 5. Your choices and rights

- **Self-hosted:** you control your data directly. The app supports account deletion and data purge on
  your instance, and a full data export (expenses, transactions, accounts, balances, and groups as
  CSV/JSON, transactions as OFX, and a ZIP archive with your receipts).
- **Demo:** demo data is transient and wiped on a schedule; you can also stop using it at any time.
- **Relay:** to have a registered email and key removed, email **privacy@cleave.money**.

Depending on where you live, you may have additional rights (such as access, correction, or deletion)
regarding data held by our operated services. Contact us to exercise them.

## 6. Data retention

- **Self-hosted:** retention is entirely up to you, the operator.
- **Demo:** sample and guest data is pruned on a recurring schedule.
- **Relay:** registration records and device tokens are kept while a backend remains registered; stale
  or unregistered device tokens are dropped. Contact us to request earlier deletion.

## 7. Children

Cleave is not directed to children and is not intended for use by anyone under the age required to
consent to data processing in their jurisdiction.

## 8. Changes to this policy

We may update this policy as the project evolves. Material changes will be reflected here with a new
"Last updated" date, and the history is visible in the project's version control.

## 9. Contact

Questions about this policy or about data held by our operated services: **privacy@cleave.money**.
Security issues: **security@cleave.money** (see [SECURITY.md](SECURITY.md) if present). Conduct
concerns: **conduct@cleave.money**.
