# Detailer appointment assignments — Milestone 4D-2

`SchedulerApi.Appointments.JobAssignments` is an internal, audited assignment
context. No HTTP/UI, invitations, Calendar, compensation or platform access is
added. Staff assignments do not affect customer booking availability or capacity.
Existing shop booking locks and appointment overlap constraints remain unchanged.

## Explicit staffing policy

One active Detailer per appointment. Only pending/confirmed appointments may be
assigned. Active employment, Detailer classification, an active shop assignment
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

Unassign before cancelling/rescheduling a covering shift, changing an assigned
appointment's start/duration/ownership, or marking it completed/cancelled.
Database guards reject those changes while an active job exists; confirming a
pending appointment remains allowed. Shift mutations return an audited
`:assigned_jobs` denial. Future combined completion/rescheduling/offboarding
workflows must close jobs and update source records atomically with auditing.

## Internal APIs

- `assign(session_credential, appointment, shop_assignment, opts)` requires no
  current assignee; returns `:already_assigned` otherwise.
- `reassign(session_credential, appointment, shop_assignment, opts)` requires an
  existing job, closes it as `reassigned`, and inserts a replacement atomically.
  Same-assignment replacement returns `:unchanged`.
- `unassign(session_credential, appointment, opts)` closes the current job as
  `unassigned`; missing jobs return `:not_assigned`.
- `list_shop_assignments(actor_user, shop, opts)` provides scoped management
  history, including closed jobs and ended workers.
- `list_own_work(actor_user, business, opts)` returns active jobs on pending/
  confirmed appointments for the actor's explicitly linked, active Detailer
  employment/current shop assignment and qualifying own-work grant.

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
`shop_id`, `work_shift_id`), UTC bounds, status and closed_at. Customer/contact,
compensation, account/session and audit data are deliberately excluded. Future
job-detail APIs need separate explicit projections and authorization.

## Integrity, locking and audit

Composite restrictive FKs enforce appointment, employment/shop-assignment and
covering-shift ownership. A partial unique index permits one active assignee per
appointment. GiST rejects active employee occupied-period overlap across shops.
Insert triggers enforce Detailer/date/shift coverage and exact appointment
snapshots even for direct SQL. Closed history cannot be rewritten/reactivated.

Lock order: business, actor user/session/membership/grants, employments in ID
order, shop assignments in ID order, shop, covering shift, appointment, job.
This matches role management and WorkSchedules' parent-first order. Business
locking serializes sensitive operations; employment locking coordinates with
termination and direct inserts. Shift/appointment source guards prevent drift.
No database transaction spans network calls; no sleeps or automatic retries.

Every committed mutation writes an immutable `appointment_assignment_audit_events`
row with actor, tenant/appointment, old/new job IDs, bounded action/outcome/reason
and UTC timestamp. Job references retain the full worker/shift relationship.
Expected denials commit only a denial event. Invalid/missing references remain
nullable, not fabricated identities. Audit or unexpected database failures roll
back the whole transaction and return `:persistence_failed`; a failed transaction
cannot also commit a rejection audit. No arbitrary input or credentials are logged.

Termination/ended assignments never delete or silently close jobs, shifts,
appointments or audit history. Own-read eligibility ends immediately; authorized
management can explicitly unassign outstanding work. A combined audited
termination workflow remains future work. No production delete API exists.

The additive migration creates empty job/audit tables, one unique identity index
on existing appointments, source guards and one bounded shift-audit denial reason.
It changes no operational rows. Plan DDL/index locks for production deployment.
Down refuses any job/audit history or retained shift `assigned_jobs` denial rather
than discard history. Tests use rollback-isolated data; independent-connection
fixtures clean only their positively owned business and users.

```sh
mix test test/scheduler_api/job_assignments_test.exs test/scheduler_api/job_assignment_integrity_test.exs test/scheduler_api/job_assignment_audit_test.exs test/scheduler_api/job_assignment_concurrency_test.exs
```
