# Protected scheduling APIs — 4F-3

Prefix `B=/api/admin/businesses/:business_id`, `S=B/shops/:shop_id`,
`T=S/appointments/:appointment_id/team`. Every route uses current opaque browser
sessions and no-store responses. Writes additionally use the existing session-bound
CSRF, exact Origin/controlled Referer checks and bounded private JSON parser.

| Method/path | Operation / allowed body |
|---|---|
| GET `S/appointments` | Upcoming pending/confirmed shop appointments; existing appointment JSON/meta contract |
| GET `T` | Active team and per-member `is_lead`; cursor pagination does not limit crew size |
| GET `S/shifts` | Authorized shop shift history |
| GET `S/employees/:employee_id/periods/:period_id/shifts` | Authorized employee-period shift history at this shop |
| GET `B/me/shifts` | Only linked actor's eligible period/assignment shifts |
| GET `B/me/work` | Only linked Detailer's eligible current-period jobs |
| POST `S/shifts` | employee_id, period_id, assignment_id, starts_at, ends_at |
| POST `S/shifts/:shift_id/cancel` | Empty object |
| POST `S/shifts/:shift_id/reschedule` | starts_at, ends_at |
| POST `T` | Add one member: employee_id, period_id, assignment_id |
| POST `T/:job_id/remove` | Empty object; remove only this member |
| POST `T/:job_id/lead` | Empty object; explicitly designate/transfer lead |
| POST `T/clear-lead` | Empty object; do not remove any member |

Management requires the existing complete same-business/same-shop grant:
`appointments_read`, `schedule_manage` or `jobs_assign` as appropriate. Business
Owners cover their business; Shop Managers only granted shops. Business Managers
and Employees gain no management authority. Own reads use the existing separate
own-shift/assigned-job policy and verified linked employment, not request actor IDs.
Archived tenants, revoked grants and account ineligibility remain fail-closed.

`employee_id` is stable identity; `period_id` is the exact employment row;
`assignment_id` identifies its employment/shop relationship; `job_id` is the team
membership row. Persisted business/shop/period relationships are resolved before
domain calls. Employee-period management reads require a retained assignment at
that shop. A forged path or body never supplies authorization. Internal DTO field
`employment_id` in responses means **period ID**, never stable employee identity.
No contacts, compensation, sessions or audit schemas are added to projections.

Apart from appointments, success responses wrap existing explicit domain DTOs/pages
in `{"data": ...}`. Shift pages retain `shifts`, team/own-work pages `assignments`,
`has_more` and `next_cursor`. UTC timestamps remain ISO strings; shifts retain their
validated timezone. Only public appointment-list projections include their existing
customer/catalog fields, behind appointment-read permission.

Reads accept `limit` 1..100/default 50 and `cursor`; shift reads also accept `from`
and `until` explicit UTC/offset instants. These are domain cursor positions, not
authority or snapshots; SQL business/shop/period filters precede ordering, limit and
projection even when a cursor originated elsewhere. Unknown query/body fields,
client status/ownership overrides and naive shift times are rejected. Appointment
sorting, status/time filters and pagination match the existing admin contract.

Writes delegate to WorkSchedules and JobAssignments, with domain rechecks,
transactions, audits, half-open employee overlap, individual covering shifts and
appointment buffer unchanged. No direct Repo mutation is used by HTTP adapters.
Cancel/reschedule with active jobs returns conflict until explicit unassignment.
Lead transfer is atomic, removal never promotes another member, and duplicate
member requests never replace unrelated members. Legacy single-assignee APIs are
not exposed/reinterpreted; their `:ambiguous_team` safeguard remains intact.

Status codes: 201 for shift/member creation, otherwise 200 success; 401 invalid
session; generic 403 unauthorized/mismatched references; 422 invalid input;
409 domain conflicts (overlap, missing coverage, ineligible assignment/Detailer,
assigned_jobs, closed/duplicate/no-member/no-lead/unchanged states); generic 503
`operation_unavailable` for audit/database failures. Domain errors roll back as
before; raw exceptions, payloads and credentials are not returned/logged.

## Verification and unsupported operations

HTTP tests cover cookie/session and CSRF rejection, role differences, separate and
same-human Owners, cross-shop/tenant spoofing, teams/leads, coverage/overlap,
terminated/management-classified workers, scheduling blockers, period-aware own
reads, pagination/allowlists and audit failure. Independent-connection HTTP races
reuse the owned concurrency fixture to prove simultaneous additions/lead changes
and duplicate conflicts preserve two members and one lead without deadlocks.

Remaining gaps: real Keycloak/browser flows; HTTP own-work reads after explicit
new-period grants beyond effective start (covered at domain level); simultaneous
HTTP shift rescheduling/offboarding/last-Owner combinations. Existing domain
independent-connection race suites remain intact. No test security bypass exists.

No admin appointment creation, customer cancellation/rescheduling, automatic team
reassignment, booking capacity change, frontend or Google Calendar is implemented.
Those require separately designed authorized domain workflows. Public booking,
existing locks/exclusion constraints and historical records remain unchanged.

```sh
mix test test/scheduler_api_web/controllers/scheduling_controller_test.exs test/scheduler_api/job_assignment_concurrency_test.exs test/scheduler_api_web/controllers/admin_appointment_security_test.exs
mix precommit
```
