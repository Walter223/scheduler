# Protected HR writes — 4F-2

All routes use the existing opaque session cookie, `RequireBrowserSession`, exact
Origin/controlled Referer validation and session-bound masked `x-csrf-token` from
`GET /api/me`. Responses are `Cache-Control: no-store`. No changes to public
booking CSRF/authentication requirements are made.

Prefix: `/api/admin/businesses/:business_id`.
Let `P` be `/employees/:employee_id/periods/:period_id` under that prefix.

| Method/path | Allowed JSON fields | Success |
|---|---|---|
| POST `/employees` | first_name, last_name, classification, starts_on; optional phone, email, home_address | 201 |
| PATCH `P/contact` | first_name, last_name, phone, email, home_address | 200 |
| PATCH `P/classification` | classification | 200 |
| POST `P/shop-assignments` | shop_id, starts_on | 201 |
| POST `P/shop-assignments/:assignment_id/end` | ends_on | 200 |
| POST `P/terminate` | empty object | 200 |
| POST `P/rehire` | starts_on | 201 |

IDs identify references, not authority. Business/employee/period and assignment
relationships are checked before delegation. A new period ID cannot be used as a
stable employee ID. Shop selection is validated by the HR domain. Query overrides,
unknown body keys, user links, status, roles, pay and audit fields are rejected.
The JSON body is limited to 64 KB and parsed only after session/CSRF checks, inside
the private admin boundary, outside ordinary request-body telemetry/debug logging.

Controllers call `Employment.HTTPWrites` solely for HTTP field/identifier
adaptation and then the existing `Employment.HR` operations. No Repo writes,
role elevation, lifecycle implementation or replacement authorization is added.
Domain transactional session/tenant/Owner checks, locking, audits and rollback
remain authoritative. Business Managers cannot terminate/re-hire protected Owners;
Shop Managers and Employees cannot perform HR writes. Last-Owner refusal remains
in the existing offboarding/RBAC workflow.

Success responses use `{"data": ...}` with existing strict domain projections,
renaming identifiers to `employee_id`, `period_id` and (for shop relationships)
`assignment_id`. Termination returns `data.employment` and `already_terminated`.
No whole schema, credential or audit payload is serialized. Repeated termination
retains domain no-op behavior; repeated/stale rehire returns a lifecycle conflict,
never an extra period. Rehire restores no membership/grants, pay, contacts or work.

Errors are bounded JSON `{"error":"code"}`:

- 401 `authentication_required`: missing/invalid/expired/revoked/ineligible session.
- 403 `forbidden`: unauthorized business/record or mismatched IDs. Existing CSRF
  boundary uses `invalid_origin` / `invalid_csrf_token` for its distinct failures.
- 422 `invalid_input`: invalid/unsupported JSON, unknown fields/query parameters,
  invalid submitted dates/classifications/identifiers or malformed payloads.
- 409 domain conflict: `outstanding_work`, `work_in_progress`, `last_owner`,
  `already_assigned`, `assignment_ended`, `employment_ended`, `unchanged`,
  `future_assignment_dates`, `legacy_termination_requires_review`,
  `offboarding_required`, `not_latest_ended_period`.
- 503 `operation_unavailable`: domain audit/database failure. Raw SQL errors and
  private values are never returned. Domain transactions roll back as before.

Tests use isolated Phoenix HTTP requests with real session cookies and CSRF from
`/api/me`, not an auth bypass. Covered: Owner/HR operations, shop/employee denial,
Owner history and last-Owner refusal, two businesses, multiple shops, period-ID
spoofing, no restoration, retained history, same-cookie other-business access,
repeated lifecycle mutations, malformed/large bodies and audit rollback.

Remaining explicit gaps: simultaneous HTTP mutation races (existing independent-
connection domain race tests remain the concurrency evidence), real Keycloak
browser flows/selector races, and future employee self-service HTTP period privacy.
No frontend, role-management endpoint, compensation mutation, migration or
production-readiness claim is introduced.

```sh
mix test test/scheduler_api_web/controllers/employee_write_controller_test.exs test/scheduler_api_web/controllers/employee_controller_test.exs
mix precommit
```
