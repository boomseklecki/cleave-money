# Security Policy

## Reporting a vulnerability

If you find a security issue in Cleave, please report it privately. **Do not open a public issue.**

- Email **security@cleave.money**, or
- Use GitHub's private vulnerability reporting on this repository.

Please include enough detail to reproduce the issue: the affected component (backend, relay, or iOS
app), version or commit, and a description of the impact. If you have a proof of concept, include it.

We will acknowledge your report, investigate, and keep you updated on a fix. Please give us a
reasonable chance to release a fix before disclosing publicly. We are grateful for responsible
disclosure and will credit reporters who want to be named.

## Scope

Cleave is self-hosted, so most deployments are operated by their owners. Reports are most useful when
they concern the software itself: authentication and scoping, token handling and encryption, the push
relay, the OFX/statement import path, or any way one user's data could reach another user.

Configuration mistakes in a specific self-hosted deployment (for example an exposed database port or a
weak admin secret) are the operator's responsibility, but reports of insecure defaults in the shipped
configuration are welcome.

## Supported versions

Cleave is early-stage software under active development. Security fixes land on `main`; please test
against the latest commit before reporting.
