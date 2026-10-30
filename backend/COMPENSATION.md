# Compensation foundation — Milestone 4C

`SchedulerApi.Employment.Compensation` provides internal authorized pay reads and
audited writes. Keycloak authenticates; Phoenix authorizes. No HTTP endpoints,
UI, payroll processing, bank/SSN/tax fields, role grants or account-linking are added.

## Storage and history

`compensation_rates` belongs to an existing employment/business through a composite
restrictive foreign key. `pay_basis` is `hourly` or `annual_salary`; currency is USD.
`amount` uses exact PostgreSQL numeric/Ecto Decimal, never float. Positive amounts
must be below one trillion USD with at most two fractional digits. API inputs are
exact decimal strings, integers or Decimal values; floats, nonfinite amounts,
fractional cents, unsupported fields and currencies fail validation. DTO amounts
are canonical decimal strings, e.g. `"25.50"` or `"85000.00"`.

Periods are `[effective_from, effective_until)` calendar dates; NULL upper bound
means open-ended. One pay arrangement applies per employment, across both bases.
A GiST exclusion constraint prevents any overlap, including direct concurrent SQL.
Database guards prevent rewriting amounts, bases, currencies, ownership or starts.
An open period can be closed once; closed periods cannot be rewritten/reopened.

`set_rate(credential, employment, attrs, opts)` appends chronologically. It may
close the preceding open period at the new start, recording that closure in the
same audit transaction. Original rate values remain intact. Same-start changes,
overlap, out-of-order inserts and retroactive changes are rejected; start must be
on/after both employment start and the current Denver date. Finite periods/gaps
are supported. Backdated corrections and replacing/cancelling scheduled rates
need a separately reviewed audited design, not history overwrites.

Employment termination updates employment/assignment status only. It does not
delete or rewrite rates, assignments or audits. Former employees' HR pay history
remains available. No current rate is returned for ended employment, even when
its last stored pay arrangement is open-ended. Restrictive foreign keys retain
referenced employment/rates; no application financial/history deletion API exists.
The migration creates empty tables; its down migration refuses to discard any
rate/audit rows and requires a reviewed preservation plan once history exists. Test-only committed fixtures are
positively owned and cleaned in dependency order.

## Authorization and projections

- `get_current_rate(actor_user, employment, opts)`: Business Owners may read within
  their business; Business Managers may read employee pay except Owner pay.
  Shop Managers get only the currently applicable rate for active Detailers with
  a current assignment at a granted active shop. No shop history/future rates.
- `list_rate_history(actor_user, employment, opts)`: HR-only, including ended
  employment, with the same Owner-pay restriction. Chronological full history.
- `get_own_current_rate(actor_user, business, opts)`: exact linked user only,
  requiring `compensation_own_read` (Business Owner/Employee under the fixed policy).
  Employee grants must match a current shop assignment. This separate own-pay
  permission can show one's own management pay; it cannot show anyone else's pay.
- `set_rate` requires `compensation_write` on the persisted employment, not merely
  a coarse business permission or classification. Only active employment accepts
  new rates. No Shop Manager/Employee write authority is introduced.

Current or historical Owner classification OR any same-business Owner grant
history prevents Business Manager access. Shop reads require Detailer classification AND no same-business
Owner/Business Manager/Shop Manager classification history or grant history on
the linked user. Revoked
management grants are deliberately included to avoid exposing historical
management pay after an Employee grant; unrelated-business roles do not block
legitimate Detailer pay. This conservative restriction remains after audited HR reclassification, including
later rates; see [HR_ADMINISTRATION.md](HR_ADMINISTRATION.md). Classifications never grant privileges.

Each decision uses a complete current role assignment and persisted business/shop
relationships. Account eligibility, email verification, membership/grant revocation
and archived scopes are evaluated in SQL. Read callers must authenticate actors
separately; never accept a caller-supplied user ID as authenticated identity.
Record structs are references, not ownership proof. General employment roster
projections remain unchanged and exclude compensation.

All rate DTOs explicitly select only `id`, `business_id`, `employment_id`,
`pay_basis`, `currency`, `amount`, `effective_from`, `effective_until`. No user,
contact, session, provider or audit fields are returned. Unauthorized reads return
`{:error, :forbidden}`; authorized absence of a current rate is `{:ok, nil}`.
`:now` is a trusted deterministic clock seam, never an HTTP date/auth override.
Date applicability uses America/Denver. Session eligibility always uses the live
Accounts clock even when the financial/test clock is injected.

## Transaction and audit boundary

Writes require an inspect-redacted `Accounts.SessionCredential`, not User/map/raw
cookie strings. The context resolves employment ownership, locks its business
(the same lock boundary as RoleManagement), then actor user/session, membership,
grants and employment. It rechecks session eligibility and record authorization
inside that transaction. Membership/grant/account revocations cannot race through
the locked eligibility rows; cooperating role-management operations serialize on
the business lock. Shop assignment creation also takes business before employment
to avoid a business/employment lock inversion. Concurrent same-date changes produce one success and one
`:effective_date_conflict`, not last-writer replacement or automatic retries.

`compensation_audit_events` stores actor, business, employment, new/closed rate IDs,
closure date, bounded action/outcome/reason and UTC timestamp. It contains no pay
amounts, credentials, tokens or arbitrary input. Expected denials commit only an
audit event. Unexpected database failures roll back the transaction and return
`:persistence_failed`; no rolled-back mutation claims a successful audit. Audit
failure also rolls back any previous-period closure and new rate. Financial writes
use `log: false` and database exceptions are not exposed to callers.

Focused verification:

```sh
mix test test/scheduler_api/compensation_test.exs test/scheduler_api/compensation_audit_test.exs test/scheduler_api/compensation_concurrency_test.exs
```
