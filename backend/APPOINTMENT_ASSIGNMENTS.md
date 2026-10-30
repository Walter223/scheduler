# Detailer appointment teams — Milestone 4D-3

`SchedulerApi.Appointments.JobAssignments` is an internal, audited assignment
context. No HTTP/UI, invitations, Calendar, compensation or platform access is
added. Staff assignments do not affect customer booking availability or capacity.
Existing shop booking locks and appointment overlap constraints remain unchanged.

## Explicit staffing policy

Zero, one or multiple active Detailers per appointment, with no crew-size limit.
An employment record may appear only once in the active team. Only pending/confirmed
appointments may be assigned. Active employment, Detailer classification, an active shop assignment
and effective employment/assignment dates at the job's shop-local calendar dates
are required. Unlinked employees are allowed; classification never grants RBAC.
Account eligibility controls the actor, not whether unlinked staff may work.

**One active shift for that exact employment/shop assignment must cover the whole
appointment plus its 30-minute buffer.** Two partial shifts do not count. Bounds
are UTC, half-open `[start,end)` and snapshotted from the stored appointment
start/duration. Exact coverage and adjacency are allowed. Timezone/DST conversion
belongs to [WorkSchedules](WORK_SHIFTS.md); no naive wall-clock values enter this
API. Future-effective assignments can support jobs within their effective dates.

Jobs for one employment/business cannot overlap, including across shops. Separate
employment records in separate businesses are not aggregated by email or identity.
One employee's overlapping shifts are already forbidden; a job exclusion remains
independent defense in depth. Assignment queries check conflicts before coverage
so an existing cross-shop job reports `:overlap` even without a second shift.

Explicitly remove all affected team members before cancelling/rescheduling a covering shift, changing an assigned
appointment's start/duration/ownership, or marking it completed/cancelled.
Database guards reject those changes while an active job exists; confirming a
pending appointment remains allowed. Shift mutations return an audited
`:assigned_jobs` denial. Future combined completion/rescheduling/offboarding
workflows must close jobs and update source records atomically with auditing.

## Internal APIs

- `add_member(session_credential, appointment, shop_assignment, opts)` adds one
  eligible Detailer; duplicate employment returns `:already_assigned`.
- `remove_member(session_credential, appointment, job_assignment, opts)` closes
  exactly the referenced member as `unassigned`; other members are untouched.
- `designate_lead(session_credential, appointment, job_assignment, opts)` explicitly
  selects an existing eligible active team member, atomically clearing the old
  lead if present. Same-lead selection returns `:already_lead`.
- `clear_lead(session_credential, appointment, opts)` removes only the designation;
  the member remains assigned. Missing lead returns `:no_lead`.
- `list_team(actor_user, appointment, opts)` returns the authorized active roster,
  including `is_lead`, with the same cursor pagination as the collections below.
  Team rosters require management authority, not merely an Employee session.
- `list_shop_assignments(actor_user, shop, opts)` retains management history.
- `list_own_work(actor_user, business, opts)` returns only the linked eligible
  Detailer's own active jobs; coworkers' jobs are not included.

Legacy `assign` still requires an empty appointment, returning `:already_assigned`
otherwise. Legacy `reassign` and `unassign` retain single-member behavior, but
return `:ambiguous_team` for multi-person teams without changing anyone. Explicit
team operations are required then. Reassignment closes the old row and inserts
another; it never transfers lead status automatically. Removing/replacing the lead
leaves the team without a lead. No new HTTP routes or callers are introduced.

Lead is optional mutable operational metadata (`is_lead`); the underlying worker,
shift, appointment, period and closed-history identity remain immutable. Each
successful operation atomically records before/after lead job IDs in the immutable
audit history. A partial unique index permits at most one active lead; a check
requires any lead to be an active team member. No existing/historical assignee is
inferred as a lead during migration. Lead status grants no RBAC authority.

Writes require the opaque Accounts `SessionCredential` wrapper. Structs are ID
references only; ownership, classification, eligibility and source times are
reloaded. Mutations accept only a trusted `:now` option for domain timestamps;
session validity always uses the current Accounts clock. No caller ownership,
price, duration, status or shift overrides are accepted.

Reads require authenticated internal callers; do not accept HTTP actor IDs.
`jobs_assign` covers Business Owners within their business and Shop Managers at
explicitly granted shops. Business Managers and Employees cannot manage jobs.
`jobs_assigned_read` additionally requires an actual linked Detailer and same-shop
complete grant; unrelated permissions/scopes are never combined. Accounts,
verification, membership/grant revocations and archived tenants are checked on
every read/write. `Authorization.authorize(user, action, job)` and
`authorized_job_assignment_ids_query/2` support future record/query boundaries.

Collections return `{:ok, %{assignments: [...], has_more: bool, next_cursor: token}}`.
Options: `:limit` 1..100 (default 50), opaque `:cursor` over `(starts_at,id)`.
Authorization SQL precedes filtering/order/pagination/projection. Job maps expose
only IDs (`id`, `appointment_id`, `assignment_id`, `employment_id`, `business_id`,
`shop_id`, `work_shift_id`), UTC bounds, status, `is_lead` and closed_at. Customer/contact,
compensation, account/session and audit data are deliberately excluded. Future
job-detail APIs need separate explicit projections and authorization.

## Integrity, locking and audit

Composite restrictive FKs enforce appointment, employment/shop-assignment and
covering-shift ownership. A partial unique index permits one active row per appointment/employment,
with a separate unique active-lead index. GiST rejects active employee occupied-period overlap across shops.
Insert triggers enforce Detailer/date/shift coverage and exact appointment
snapshots even for direct SQL. Closed history cannot be rewritten/reactivated.

Lock order: business, actor user/session/membership/grants, employments in ID
order (including all existing team members), shop assignments in ID order, shop,
covering shift, appointment, jobs in ID order.
This matches role management and WorkSchedules' parent-first order. Business
locking serializes sensitive operations; employment locking coordinates with
termination and direct inserts. Shift/appointment source guards prevent drift.
No database transaction spans network calls; no sleeps or automatic retries.

Every committed mutation writes an immutable `appointment_assignment_audit_events`
row with actor, tenant/appointment, old/new job IDs, before/after lead job IDs,
bounded action/outcome/reason and UTC timestamp. Job references retain the full worker/shift relationship.
Expected denials commit only a denial event. Invalid/missing references remain
nullable, not fabricated identities. Audit or unexpected database failures roll
back the whole transaction and return `:persistence_failed`; a failed transaction
cannot also commit a rejection audit. No arbitrary input or credentials are logged.

Termination/ended assignments never delete or silently close jobs, shifts,
appointments or audit history. Own-read eligibility ends immediately; authorized
management can explicitly remove outstanding members. Here `active` means an
unclosed assignment, not proof of continued worker eligibility; terminated staff
cannot receive jobs, become leads or use own-work reads. Existing deferred
offboarding is preserved rather than silently deleting or rewriting history. A
combined audited termination workflow remains future work. No production delete API exists.

The new additive migration replaces the single-assignee index with per-employment
uniqueness, adds default-false lead metadata and nullable audit references, extends
the bounded audit vocabulary and permits audited active lead changes. It preserves
all IDs and existing data, including prior audit rows; no lead is backfilled.
WorkSchedules and appointment source guards already inspect every active job, so
no booking/availability/shift scheduling algorithm changes are needed. Plan DDL
locks and drain old single-assignee writers before deployment; old application
versions must not run against multi-member data. Down refuses new team/lead
history rather than erase it or force a single-assignee conversion.

A populated legacy-data migration round trip is tested in a rollback-isolated
schema. Tests use isolated fixtures; independent-connection cleanup is restricted
to positively owned business/user IDs. Development data is never migrated by tests.

```sh
mix test test/scheduler_api/appointment_team*_test.exs test/scheduler_api/job_assignment*_test.exs
```

Milestone 4F-3 exposes the existing operations through
[protected scheduling HTTP APIs](SCHEDULING_API.md), with no booking-rule changes.
