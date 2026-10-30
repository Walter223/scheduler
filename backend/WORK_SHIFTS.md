# Employee work shifts — Milestone 4D-1

`SchedulerApi.Employment.WorkSchedules` owns explicit employee work shifts. No
HTTP, UI, recurring generation or Calendar integration exists. Explicit
[appointment assignments](APPOINTMENT_ASSIGNMENTS.md) now require covering shifts.
Shifts do not participate in appointment availability, hours, buffers, capacity
or appointment scheduling locks. Compensation behavior is unchanged.

## Persistence and time

`work_shifts` references the exact employment/shop assignment through a composite
foreign key `(assignment_id, employment_id, business_id, shop_id)`. All deletes are
restrictive. UTC whole-second `starts_at` / `ends_at` form `[start,end)`; start must
precede end. A GiST exclusion constraint rejects overlapping active shifts for
one employment/business, including different shops. Adjacent shifts and different
employees can overlap without imposing appointment resource rules.

Creation requires active employment, an active assignment and shop, and an
interval covered by the employment/assignment calendar dates in that shop's
persisted timezone. Future-effective assignments support advance planning when
the shift falls within their dates. End is exclusive, so an exact local-midnight
end belongs to the preceding occupied calendar day.

Use explicit ISO8601 timestamps with Z/UTC offset, or DateTime values. Naive local
strings and fractional seconds are rejected. For local input use
`local_to_utc(shop, naive_datetime, offset_seconds)`: the shop's timezone is reloaded
and PostgreSQL's IANA rules verify a round trip. A spring-forward gap is rejected;
each fall-back occurrence requires its explicit correct offset. No browser/OS
zone, caller-supplied shop timezone, or default ambiguous-time choice is trusted.
No timezone dependency is added. Each shift snapshots its validated timezone;
UTC instants and their original interpretation remain intact if shop settings change.

## Internal APIs and authorization

- `create_shift(session_credential, assignment, attrs, opts)` accepts only
  `starts_at` and `ends_at`. Ownership, timezone and status are server-assigned.
- `cancel_shift(session_credential, shift, opts)` closes an active record.
- `reschedule_shift(session_credential, shift, attrs, opts)` marks the original
  superseded and creates a linked replacement at the same assignment. Both changes
  and their audit are atomic; moving shops/employees is not silently supported.
- `list_shop_shifts(actor_user, shop, opts)` returns scoped management history.
- `list_own_shifts(actor_user, business, opts)` returns only the linked actor's
  shifts at matching active employment/assignments and granted active shops.
- `get_shift(actor_user, shift)` accepts either complete management or own-read
  authority for the persisted record. Caller struct ownership/status is not proof.

Business Owner `schedule_manage` covers active shops within their business. Shop
Manager authority covers explicitly granted shops only. Business Manager HR/finance
and Employee grants do not supply scheduling management. `schedule_own_read`
remains Business Owner/Employee under the fixed policy; own access requires a real
eligible user link. Primary employment classification grants no authority.
Every decision uses one complete current grant plus persisted tenant relations;
no role/scope flattening or caching. Account status/verified email, memberships,
grants and archived shops/businesses are checked on each request/query. Read
callers must authenticate actors separately, never accept an HTTP-supplied user ID.
Writes require an actual opaque Magnum SessionCredential, not User/map/raw token.

Reads explicitly project only `id`, `assignment_id`, `employment_id`, `business_id`,
`shop_id`, UTC boundaries, `timezone`, `status`, `supersedes_id`, `closed_at`. No
contact, compensation, credentials or audit fields are serialized. Management
reads retain cancelled/superseded/terminated-worker history at authorized shops.
Own reads lose access when the linked employment/assignment ends, preserving the
underlying records for authorized management/history.

Collections return `{:ok, %{shifts: maps, has_more: boolean, next_cursor: token}}`.
Options: `:limit` 1..100 (default 50), opaque `:cursor` for `(starts_at,id)`, optional
`:from` / `:until` explicit instants selecting intersecting half-open windows.
Default is chronological history, not upcoming-only; callers can supply a window.
SQL authorization precedes filters, order, limit and cursor creation. Unauthorized
rows cannot influence page contents/metadata. Cursors never confer authority.
Unknown options/malformed ranges return `:invalid_options`; denials are generic
`:forbidden`. Write-only `:now` is a trusted clock seam for timestamps, never an
HTTP authentication override. Session validity always uses the live Accounts clock.

## Mutation, audit and retention

Lock order: business, actor user/session/membership/grants, employment, assignment,
shop, shift. This follows role management, compensation and employment locking.
Admission is rechecked while locked. Parent locking serializes same-employment
inserts even for direct SQL, with the exclusion constraint as defense in depth.
Expected overlap/not-active/eligibility denials return normal errors and commit
only a denial audit. There are no sleeps or automatic write retries.

`work_shift_audit_events` stores bounded action/outcome/reason, actual actor,
assignment/tenant IDs, original/replacement shift IDs and UTC timestamp. It stores
no arbitrary payload, tokens, contact or pay data. Audit failure rolls back the
entire mutation, including supersession; unexpected DB failures similarly return
`:persistence_failed` with no false success audit. Writes disable SQL value logging.

Cancelled/superseded rows cannot be reactivated or rewritten. Repeated cancellation
or replacement of an inactive row returns `:not_active`; an identical replacement
returns `:unchanged`. Terminating employment or ending an assignment never deletes
or silently cancels historical/future shifts. New creation/replacement then fails
eligibility; a still-authorized manager can explicitly cancel outstanding shifts
with an audit. A combined audited offboarding workflow is future work. Active appointment jobs
must first be explicitly unassigned before shift cancellation/rescheduling; those
changes otherwise return the audited `:assigned_jobs` denial.

The additive migration creates empty shift/audit tables and adds a unique identity
index to existing assignments (IDs already guarantee uniqueness). No rows are
backfilled or changed. Review index/foreign-key locking time on a large production
assignment table and btree_gist installation privileges. Down refuses nonempty
shift/audit tables rather than discard history. Test-only committed fixtures are
positively owned and cleaned children-before-parents; no production deletion API
is added.

```sh
mix test test/scheduler_api/work_schedules_test.exs test/scheduler_api/work_shift_audit_test.exs test/scheduler_api/work_shift_concurrency_test.exs
```
