
# Backend Guidelines

Root instructions apply. Run Mix commands from `backend/`.

## Architecture and data ownership

- Business logic and persistence belong in contexts and Ecto schemas under `lib/scheduler_api/`; keep controllers, routes and JSON renderers in `lib/scheduler_api_web/`.
- Migrations/seeds: `priv/repo/`; configuration: `config/`; tests/helpers: `test/`.
- Resolve authoritative business/shop ownership server-side. Never trust caller-supplied ownership, prices, durations or protected status fields.
- Resolve the configured default tenant explicitly; never select an arbitrary first business/shop.
- Filter queries by business/shop before pagination. Preserve tenant-scoped composite foreign keys, database constraints and appointment price/duration snapshots.
- Preserve scheduling rules, shop-scoped advisory locking, exclusion constraints, occupied-period calculations and post-appointment buffers. Availability checks and appointment creation must enforce the same boundaries.

## Database changes

- Prefer additive Ecto migrations generated with `mix ecto.gen.migration descriptive_name`.
- Do not rewrite applied historical migrations or destroy existing data without explicit authorization.
- Preserve existing rows, ownership and constraints. Check compatibility and data preservation when migrations affect stored records.
- Keep tests isolated from development and production-like data.

## Authentication and authorization

- Keycloak authenticates; Phoenix owns identity, sessions and authorization.
- Preserve immutable issuer/subject identity, pending-account denial, email-verification requirements and account-status eligibility.
- Preserve revocable opaque server-side sessions, cookie/CSRF protections, one-time login transactions and provider-token non-persistence.
- Never treat successful authentication as business/shop authorization. Role and shop scope must be established and enforced server-side.
- Existing admin APIs are not yet protected by RBAC and must not be publicly deployed until server-side authentication, authorization and tenant-scope enforcement are implemented and verified.
- Do not weaken authentication controls or introduce bypasses for development convenience.

## Relevant references

Read only when the task requires them:
- Scheduling, tenants, concurrency or admin listing: relevant sections of `README.md`.
- Accounts lifecycle and session primitives: `ACCOUNTS.md`.
- OIDC, browser authentication, cookies, CSRF or auth testing: `AUTHENTICATION.md`.
- Keycloak/Compose operations: `../docs/auth-development.md`.

For authentication behavior, prefer the current implementation and `AUTHENTICATION.md` over historical stage notes.

Never print secret-bearing environment files or rendered secret configuration. Do not reset Keycloak or its volumes as a troubleshooting shortcut.

## Implementation conventions

- Follow established Elixir, Phoenix and Ecto patterns; keep modules and functions focused.
- Use changesets for validation and appropriate Ecto queries for data access.
- Never create atoms from untrusted user input.
- Preload required associations and preserve explicit database ownership boundaries.
- Prefer standard time/date APIs and deterministic, bounded concurrency.
- Use Req for new application-level HTTP integrations when appropriate; preserve OIDCC's existing documented transport unless a change is justified.
- Avoid introducing new frameworks, adapters or dependencies without a demonstrated need.

## Verification

During development:
- Run focused tests, such as `mix test test/path_test.exs` or `mix test --failed`.
- Add or adjust tests for changed behavior, especially authorization, tenancy, scheduling and concurrency.

At backend checkpoints:
- Inspect the `mix precommit` alias and run it once.
- Only run additional formatting, test or warnings-as-errors compilation commands when the alias does not cover them, a failure requires investigation, or the task explicitly requires them.
- Run cross-stack/browser integration tests only when affected functionality or milestone acceptance criteria requires them.

For tests:
- Use isolated, disposable fixtures.
- Prefer deterministic synchronization and injected clocks over arbitrary sleeps.
- Test concurrency with appropriate independent database connections when relevant.
- Ordinary backend tests must remain independent of live Keycloak.
- Real-provider auth tests are separate and follow `AUTHENTICATION.md`, including port checks and cleanup requirements.
- Never point test fixtures at persistent development data.
