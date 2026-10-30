# Secure rehire and period history — 4E-2B

`Employment.HR.rehire_employment(credential, previous_period, starts_on)` creates a
new empty employment period. `HR.list_employment_history(actor_user, period)`
provides an explicitly projected, HR-authorized timeline. No HTTP/UI, account
provisioning, payroll, Keycloak changes or grant restoration is implemented.

## Stable identity, immutable periods

Existing `employments.id` remains the **period ID** used by compensation, shop
assignments, shifts, jobs, offboarding and classification audits. A new immutable
`employee_id` references the first period in the same business. That retained row
anchors the stable employee identity without another profile/Keycloak/user table.
Existing records backfill `employee_id=id`; existing IDs and child references are
unchanged. Unlinked employees have separate identities; no email matching occurs.

The linked `(business_id,user_id)` unique index now applies to identity/root rows.
Period inserts must preserve the root's business and exact nullable user ID. New
identity links retain existing verified-user/active-membership checks. A continuing
period may retain its previously established user link while that account or
membership is disabled; this is identity continuity, not activation or relinking.
The user, memberships and grants are never changed by rehire.

Database safeguards: restrictive composite identity/audit FKs, immutable identity
and ended rows, one active period per employee, inclusive-date GiST non-overlap,
and a parent-locking insert guard. A child must reference an actual identity/root,
follow the latest ended period, and have a strictly later start date and a retained
successful offboarding audit. Same-day end/rehire is rejected because employment
dates are inclusive. Future-effective and explicitly backdated starts are accepted
when strictly after the prior end; no historical work is imported into them.

The API requires the exact latest ended period. Repeated/stale requests return
`:not_latest_ended_period`; no second period/audit is created. Legacy termination
without secure offboarding returns `:offboarding_required`. Rehire does not repair
or silently reconcile legacy access/work. No ended row is reactivated. Offboarding must target the current period ID; a
repeat request for an older completed period remains a no-op and never terminates
a newer period implicitly.

## Authorization, transaction and audit

A live active/verified session and current same-business HR grant are required.
Business-first locking is followed by sorted business eligibility/membership/grant
locks, actor session, stable identity and requested period. Authorization is checked
again using the locked persisted period. Business Owners may manage their business;
Business Managers cannot rehire currently/historically Owner-classified employees
or employees with protected same-business Owner grant history. Classification
history sensitivity follows the stable employee across all periods, including
unlinked staff. Classification never creates permissions. Last-Owner safeguards
and explicit Owner-managed transitions remain unchanged.

`employment_rehire_audits` records actor, business, stable employee, previous/new
period IDs and UTC timestamp. Composite FKs bind both periods to the same employee;
unique previous/new references prevent duplicate historical transitions. Audit
updates are forbidden. Inserted period, its classification history and audit commit
atomically; database/audit failure rolls back as `:persistence_failed`. Expected
denials roll back without false success events. There are no sleeps or retries.

## No restoration; period-specific privacy

The new period copies only its established user reference, name and classification.
Phone/email/home address start NULL. It has no shop assignments, rates, shifts or
jobs. No membership, grant or account status is activated, even for suspended users.
A separate authorized role-management workflow can later restore a membership and
explicitly grant permissions; separate HR/scheduling/pay commands populate new data.

Existing self-service queries select active employment and exact period/assignment
IDs in SQL. Ended prior periods remain excluded even after explicit new grants and
shop assignment. Old open-ended rates stay attached to the ended period; they do
not become current pay. Prior shift/job IDs, contacts and HR history are not made
available through employee projections. Future-effective dates retain each existing
query's eligibility rules; login alone never supplies scope.

HR may retrieve retained period timelines and authorized compensation history.
Active rosters show the active effective period; Former Employees lists retained
ended periods, including a rehired person's earlier periods. Future UI must group
by `employee_id` via the timeline, not infer one person per roster period. Timelines
include only period identity, name, classification, status and dates; no provider,
session, contact, compensation or raw audit schemas. HR history callers must be
properly authenticated, not chosen from HTTP-supplied actor IDs. Pagination for a
future history HTTP surface remains deferred.

## Migration, tests and remaining 4F work

Only the isolated test database is migrated during verification. The additive
migration backfills identities under an exclusive employment-table lock; plan a
maintenance/drained-writer deployment because old single-period writers must not
run against the new model. No operational child history is rewritten. Down refuses
any child period or rehire audit instead of discarding history. A populated legacy
migration round trip verifies existing fields/IDs/history survive.

Focused tests cover multiple periods, explicit post-start self-service privacy,
Owner/management history, cross-business and multi-shop preservation, account-state
safety, DB constraints, duplicate/concurrent requests, HR revocation races and audit
rollback. Fixtures are isolated; committed concurrency data is positively owned and
cleaned children-before-parents.

**4F gap:** real-cookie HTTP tests across termination/rehire and two businesses,
selector/cursor attacks on future employee/history endpoints, and UI period privacy.
No new HTTP surface exists yet; context tests do not substitute for those checks.

```sh
mix test test/scheduler_api/rehire_test.exs test/scheduler_api/rehire_migration_test.exs test/scheduler_api/employment_hr_concurrency_test.exs test/scheduler_api/owner_termination_concurrency_test.exs
mix precommit
```
