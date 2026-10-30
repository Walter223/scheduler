# Secure employee offboarding — 4E-2A

`Employment.HR.terminate_employment(session_credential, employment)` is the internal
atomic HR workflow. IDs are references; ownership and linked user are reloaded.
There is no HTTP/UI, rehire, payroll change, invitation or platform bypass.

## Authorization and access

Current active/verified Accounts sessions and one complete `employment_manage`
grant are required in an active business. Owners and Business Managers may act;
Shop Managers/Employees cannot. Eligibility is checked again under locks.
`RoleManagement.revoke_employment_access/2` is a narrow HR revocation primitive:
it resolves only the target's persisted active employment and matching membership.
It does not give Business Managers general role-management permission. Non-Owner
HR cannot remove protected Owner access; existing last-eligible-Owner protection
always applies. Transfer ownership first if it would leave no eligible Owner.

A linked user's membership and all active grants in this business are revoked
through the existing audited RBAC lifecycle. Other businesses, account status,
Keycloak identity and global sessions are untouched. Subsequent authorization
checks observe revocation immediately. Sessions do not carry business permissions.

## Transaction and work policy

The business lock is first. Before employment/child locks, sorted business user,
membership and grant locks match RoleManagement; then the actor session is locked
and rechecked. The employment, assignments, shops, shifts, appointments and jobs
are locked in stable parent-first order. Cooperating scheduling/HR/RBAC operations
serialize, and direct shift/job inserts also take the employment lock.

The captured UTC instant separates future from historical work:

1. Refuse in-progress shifts/jobs (`start < now < end`); no implicit interruption.
2. Remove only this employment's active future jobs (`start >= now`), clearing its
   lead flag without promoting another member. Preserve other team members.
3. Cancel only active future shifts, after their jobs are unassigned.
4. End active shop assignments, preserving IDs and recording per-assignment audits.
5. Revoke the linked business membership/grants, retaining RBAC audit history.
6. Mark employment ended and write one immutable offboarding summary audit.

Each job removal and shift cancellation uses the existing domain schemas and audit
contracts inside this HR transaction. These private, exact-target operations do
not impersonate a scheduling role or broaden the normal JobAssignments/WorkSchedules
permissions. No record is deleted, rates/classification history are not rewritten,
and completed historical shifts/jobs retain their existing records/status.

Termination uses today's Denver date, consistent with existing employment rosters.
It refuses `:future_assignment_dates` when employment or retained assignment dates
cannot fit that date. The existing active/ended date model cannot represent ending
a not-yet-effective relationship before its start without inventing dates. That
requires a separately designed cancellation lifecycle, not a silent rewrite here.

Every nested failure explicitly aborts the outer transaction; nested Ecto
transactions are not savepoints. Audit/database failures return
`:persistence_failed`; expected errors include `:forbidden`, `:last_owner`,
`:work_in_progress`, `:future_assignment_dates`, `:legacy_termination_requires_review`. Rejected transactions retain no
partial work/access changes or success/child-denial audits. A separate failed-attempt
security log is deferred rather than claim an audit survived rollback.

Legacy ended records without a completed offboarding audit return
`:legacy_termination_requires_review`; no success is claimed for potentially live
access/work left by the old persistence helper. Reconciliation is deferred.

A currently authorized repeated request returns `already_terminated: true` without
new history. Authentication/authorization still precedes this check; a self-offboarded
user cannot reuse revoked HR access. Successful results contain only the minimal
employment identity/classification/status/dates and `already_terminated` flag.

## Retained records

`HR.list_former_employees(actor_user, business)` returns explicit HR contact/status
projections for ended records, authorized in SQL using current business HR scopes.
It exposes no account/session/pay/audit schemas. Active rosters and own-work reads
continue excluding ended employment. Pagination for a future Former Employees HTTP
surface remains to be added; this initial internal collection is not an HTTP API.

The additive migration creates an empty `employment_offboarding_audits` table with
restrictive tenant-consistent employment/membership/actor FKs and unique employment
ID, immutable updates and nonnegative summary counts. Down refuses retained audits.
No existing operational rows or development users are changed by migration/tests.

```sh
mix test test/scheduler_api/offboarding_test.exs test/scheduler_api/employment_hr_concurrency_test.exs
mix precommit
```
