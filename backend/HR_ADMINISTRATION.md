# HR administration — Milestone 4E-1

`SchedulerApi.Employment.HR` provides internal, session-authorized HR writes.
No HTTP/UI, payroll, employment termination, offboarding/rehire, account linking,
invitations or platform administration is added. Classification never grants RBAC.

## Operations and projections

- `create_employment(credential, business, attrs, opts)` creates an active,
  **unlinked** business-owned employment record. Allowed fields: `first_name`,
  `last_name`, `classification`, `starts_on`, `phone`, `email`, `home_address`.
  No account is created or matched by email; `user_id` and role fields are rejected.
- `update_contact(credential, employment, attrs, opts)` accepts only `first_name`,
  `last_name`, `phone`, `email`, `home_address`. Names are required/max 100; optional
  fields can be cleared, are trimmed, and have existing DB size limits (32/320/1000).
  Supplied email must have a basic email shape. Unknown or duplicate atom/string
  keys reject the entire request; no partial mass assignment occurs.
- `change_classification(credential, employment, classification, opts)` accepts
  only `detailer`, `shop_manager`, `business_manager`, `business_owner`. Changes
  are immediate, not backdated or scheduled. Identical classification is a denial
  (`:unchanged`), not a new historical event.
- `assign_shop(credential, employment, shop, %{starts_on: date}, opts)` requires
  the same active business/shop, valid dates and no duplicate active assignment.
- `end_shop_assignment(credential, assignment, date, opts)` ends just that shop
  relationship, retaining its ID/history and leaving employment active. Status
  changes immediately; a future end date is not a scheduled background transition.
  Ended rows stay immutable. A later shop assignment gets a new ID.

All methods return `{:ok, map}` or bounded `{:error, reason}`. Employment responses
allow only IDs, name/contact, classification, lifecycle status and dates. Shop
responses allow only IDs, tenant/employment/shop, status and dates. User schemas,
credentials, pay and internal audit fields are never returned. No bulk HR write
or history-deletion API exists. Ended employment cannot be edited through HR.

## Authorization and locking

Writes require the actual opaque Accounts `SessionCredential` wrapper. User structs,
claimed IDs, raw token strings and arbitrary maps do not establish actor identity.
Business Owners and Business Managers require one complete current
`employment_manage` grant in the persisted business. Shop Manager and Employee
roles do not supply HR authority, even at assigned shops. Invalid sessions,
account/verification changes, revoked memberships/grants and archived businesses
fail closed. Shop changes additionally require an active, same-business shop.

Lock order: business, actor user/session/membership/grants, employment, shop
assignment (for ending), shop. Authorization and eligibility are reloaded while
locked. This matches RoleManagement, Compensation, WorkSchedules and JobAssignments.
Business locks serialize HR updates; parent employment locks coordinate with
termination and direct shift/job inserts. Concurrent disjoint contact edits retain
both changes; same-field edits are serialized last-writer-wins, with each committed
change audited. Duplicate shop assignments return a normal audited denial.

The optional trusted `:now` clock sets domain/audit timestamps. Authentication and
outstanding-work checks use live Accounts/database time; a caller-selected clock
cannot revive sessions or hide future shifts. No network calls, sleeps or retries
occur inside these transactions.

## Work integrity and lifecycle boundaries

Classification changes reject any unclosed active job or active shift that has
not finished. This conservative policy applies in either classification direction;
resolve work explicitly through the audited scheduling/team APIs first. A DB
employment trigger independently enforces this classification safeguard.

HR shop-assignment ending rejects any active job at that assignment, any ongoing/
future active shift, or an active historical shift whose occupied shop-local date
would fall after the proposed end. End is exclusive for shift occupancy, so exact
local-midnight endings use the preceding day. Other shop relationships are not
ended. Checks happen under the employment lock, before mutation, so new shifts/jobs
cannot race past a successful end.

Existing low-level `Employment` persistence helpers remain trusted fixture/internal
primitives, **not authorized HR entry points**. Existing deferred termination
behavior is unchanged; this milestone introduces no offboarding workflow. Do not
expose those helpers through future controllers. Use HR for these management writes,
and separately design audited termination/account-linking workflows later.

## Classification history and pay privacy

`employment_classification_history` is populated by a database trigger on creation
and every classification change, including direct SQL. Its tenant FK is restrictive;
old/new classifications, source and timestamp cannot be rewritten. The migration
records only each existing classification observed at migration time (`baseline`),
not fabricated earlier promotions or identity/account information.

HR creation/classification events link to the exact generated history row. Mutable
contact values are excluded from audits; only changed field names are recorded.
`employment_hr_audit_events` retains actor, tenant/employment/shop assignment,
action/outcome/bounded reason, classification-history reference and UTC timestamp.
Composite FKs prevent cross-tenant references. Updates are forbidden. Mutations,
classification history and audit insertion commit or roll back together. Expected
denials commit only denial audits; unexpected DB/audit failures roll everything
back as `:persistence_failed` and cannot also claim a committed denial/success.

Compensation authorization now includes **all past classifications**, in addition
to existing current/revoked management role history. Former Owner pay stays blocked
for Business Managers; former management pay stays blocked for Shop Managers even
after reclassification to Detailer or an Employee grant. This deliberately protects
all rates of such employment, including later rates, until a separately approved
rate-specific sensitivity design exists. Own-pay and Business Owner access retain
their existing policies. No pay values/history are rewritten.

## Migration and verification

The additive migration creates history/audit tables and replaces only the employment
classification guard; identity, user-link, tenant, ended-history and scheduling
constraints remain. Existing operational rows are not updated. Plan DDL/backfill
locks for deployment. Down refuses changed classification or HR audit history
rather than discard it; a data-preserving rollback then requires review.

Tests use rollback-isolated fixtures and a populated migration round trip in an
isolated schema. Independent-connection fixtures remove only positively owned test
rows in FK order. Development data is not migrated by these checks.

```sh
mix test test/scheduler_api/employment_hr*_test.exs
mix precommit
```

Milestone 4E-2A adds [secure atomic offboarding](OFFBOARDING.md) through
`HR.terminate_employment/2`, plus authorized retained former-employee projections.
The earlier low-level termination helper remains a trusted persistence primitive.

Milestone 4E-2B adds [secure rehire and period history](REHIRE.md), with no
automatic restoration of access, pay, private contacts or work.

See [protected HR write APIs](HR_WRITE_API.md) for the 4F-2 HTTP adapters,
session-bound CSRF requirements, payload allowlists and safe error contract.
