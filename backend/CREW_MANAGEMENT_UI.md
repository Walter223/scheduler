# Admin appointment crew management — 5D-2

The existing calendar detail panel now loads the complete authorized active team,
following every 100-member page without a crew-size cap. It displays business-specific
employment first/last names and optional Lead. No contacts, compensation, account
identities or audit records enter this projection.

Owners and assigned Shop Managers reach the panel through current server-derived
operational calendar capabilities. Pending/confirmed appointment controls add or
remove exactly one member, designate/transfer Lead, or clear Lead. Removing a Lead
leaves no Lead; no automatic promotion or legacy single-member replacement occurs.
Completed/cancelled appointments retain a read-only team. Backend authorization
remains mandatory; Business Managers and Employees gain no scheduling permissions.

## Minimal API additions

`GET /api/admin/businesses/:business_id/shops/:shop_id/appointments/:appointment_id/team/candidates`
requires a live browser session and current complete `jobs_assign` scope, with the
existing private no-store boundary. Only `limit` (1..100, default 50) and `cursor`
are accepted. The cursor binds actor/appointment; ownership and access are rechecked
on every page. Response is `{data:{candidates,has_more,next_cursor}}`; each candidate
contains only `employee_id` (stable identity), `period_id`, `assignment_id`,
`first_name`, `last_name`.

Eligibility is filtered in SQL before ID ordering/pagination: active Detailer period,
active same-business/shop assignment, effective dates across the whole buffered
appointment in shop-local time, a single active covering shift, no overlapping
active job, and a pending/confirmed appointment. Existing members are excluded by
occupied-period overlap. Candidate results are advisory: concurrent work, eligibility
or access changes can invalidate them; all writes continue to use JobAssignments'
locked authorization, eligibility, overlap, coverage, audit and database constraints.
No assignment policy or persistence changes are introduced.

Existing team GET adds only first_name/last_name to its authorized member DTO.
Other job/own-work projections remain unchanged. Existing POST team/add, member
remove/lead and clear-lead endpoints and strict payloads are reused unchanged.

## Browser safety and behavior

A fresh `/api/me` lookup supplies the existing masked session-bound CSRF token for
each mutation; it is transient and never persisted in browser storage. Existing
same-origin cookies and backend Origin/CSRF validation apply. A synchronous submission
lock and disabled controls prevent duplicate submissions. No optimistic team edits
are made: team/candidates and calendar crew summaries refresh after success or a
confirmed domain rejection. Network ambiguity requires refresh before retrying.
Missing coverage, overlapping work and lifecycle/concurrent conflicts have bounded
safe messages; 401/403 clear private calendar/detail state.

Business/shop keyed panels unmount on switching, abort requests and ignore late
responses, including responses to already-committed writes. Date/filter/page changes
close the detail panel. Native labeled selects, buttons, list semantics, keyboard
operation and existing responsive styles are retained. Requests do not extend
absolute sessions or introduce background status polling.

## Verification boundaries

Focused HTTP tests cover candidate scope, cursor pagination, minimal fields,
already-assigned/absent-shift exclusion and Owner/Shop Manager versus Manager access.
Existing scheduling and independent-connection job suites retain duplicate/overlap,
wrong tenant/shop, terminated Detailer, shift/assignment eligibility, concurrent
addition/lead, audit rollback and session/CSRF enforcement.

Component tests exercise independent add/remove, lead transfer/clear, read-only
closed appointments, duplicate submission locking, aborted mutation responses,
revocation/session errors and coverage/overlap/duplicate error feedback.
Two real-Keycloak browser cases exercise Owner and Shop Manager zero-to-two-member
crew changes, lead designation/transfer/clear/removal, unaffected teammates, mobile
keyboard removal and logout with disposable run-owned staff. Browser-level
simultaneous writes and exhaustive eligibility failures remain HTTP/domain coverage;
there is no browser claim for those combinations. Reproduce with `npm run test:auth`
using the isolated runner/free ports documented in [ADMIN_CONTEXT.md](ADMIN_CONTEXT.md).

No migrations, development-data changes, appointment lifecycle mutations, shift UI,
booking capacity changes or provider integration are part of this milestone.

Checkpoint results: `mix precommit` passed 517 backend tests; the final focused
SchedulingController run passed 11 tests, including oversized-cursor rejection.
`npm run test:component` passed 83 tests; lint and build passed.
`npm run test:auth` passed 22 real-Keycloak cases with zero retries, and
`npm run test:e2e` passed 24 anonymous browser/API cases using two workers.
Runner prerequisite tests passed 2 tests. The first browser attempt exposed an
ambiguous test selector and missing assignment-audit cleanup; both were corrected,
the failed run's guarded owned fixtures recovered, and the final runner verified
complete identity/client and SQL fixture cleanup. Ports 4002/5174 were released;
user-owned 4000/5173 processes were preserved.
