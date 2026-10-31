# Protected HR read APIs — Milestone 4F-1

All routes below are GET-only, under the existing `RequireBrowserSession` admin
pipeline. Every response has `Cache-Control: no-store`. Sessions and current
persisted grants/account/tenant status are checked for every request and included
in SQL authorization scopes. These reads need no CSRF token; no mutation or
self-service endpoint is introduced. Login alone grants no business/shop access.

## Routes and identity

| Route under `/api/admin` | Authority | Result |
|---|---|---|
| `/businesses/:business_id/employees` | Business Owner/Business Manager, same business | Stable employee directory, one latest period per identity |
| `/businesses/:business_id/shops/:shop_id/employees` | Owner or Shop Manager, complete same-shop grant | Current active assigned-shop contact roster |
| `/businesses/:business_id/employees/:employee_id` | Same-business HR | Latest period profile, including retained former employee |
| `/businesses/:business_id/employees/:employee_id/periods` | Same-business HR | Retained period timeline |
| `/businesses/:business_id/employees/:employee_id/periods/:period_id` | Same-business HR | Explicit period profile, verified against that stable identity |

`employee_id` is the first-period identity anchor; `period_id` is a particular
`employments.id`. They happen to match initially. A later period ID never aliases
an employee route. Ownership comes from persisted relationships and complete grants,
not path selectors, cookies or caller-supplied ownership fields. Shop Managers
cannot use generic employee profiles or HR history; Employees cannot use any of
these administrative routes, including their own earlier periods. A Business
Manager uses business HR routes, without inheriting shop-operational roster access.

Directory `status=active` (default) selects latest active periods whose Denver
start date has arrived. `status=former` selects identities whose latest period is
ended. A rehired person's ended earlier period is available in HR history, not
as a second Former Employee directory entry. `status=all` includes all latest
periods, including future-effective active hires with explicit `starts_on`.
Other routes accept no status filter. Shop rosters require active/current employment
and shop assignment; ended workers/assignments and archived shops are excluded.

## Projections and pagination

Directory, roster and timeline responses:

```json
{"employees": [], "meta": {"has_more": false, "next_cursor": null, "timezone": "America/Denver"}}
```

Profiles return `{"employee": {...}}`. Contact projections contain only
`employee_id`, `period_id`, `business_id`, `first_name`, `last_name`, `classification`,
`status`, `starts_on`, `ends_on`, `phone`, `email`, `home_address`, `shops`. Nullable contact
fields have no identity-provider fallback. `shops` contains allowlisted period-specific
assignment labels/dates: HR sees retained relationships at active business shops;
shop rosters expose only current relationships at the requested shop. Timelines
omit phone/email/home address and shop relationships.
Dates serialize as ISO dates. No user identifiers, sessions, credentials, payroll,
compensation values, raw schemas or audit payloads are serialized.

Collections accept `limit` 1..100 (default 50) and `cursor`. Directory additionally
accepts `status=active|former|all`. Directory and shop roster also accept optional
`q` (literal case-insensitive name substring, up to 100 UTF-8 bytes) and fixed
`classification`. These SQL filters precede ordering/pagination; filtered cursors
bind the normalized search/classification while unfiltered contracts remain intact.
Unknown parameters, malformed selectors/filters
or cursors return generic 422 `{"error":"invalid_options"}`. Path parameters
are read independently of query parameters; `business_id`, `shop_id`, `user_id`
or ownership overrides in query strings are rejected.

Directory/shop pages order by stable employee ID; timelines by period ID (new
period IDs follow retained earlier periods). SQL scope, latest-period selection,
status/date filters and distinct-grant deduplication precede pagination/projection.
No total counts are exposed. Cursors are bounded unsigned Base64URL positions,
scoped to route, business, shop/employee and status. They confer no authority;
reuse in another scope/filter returns 422. Profiles/timelines with nonexistent,
foreign or mismatched identities return the same generic 403 as insufficient
permission. Missing/expired/revoked/ineligible sessions return generic 401
`{"error":"authentication_required"}`; denied scope returns `{"error":"forbidden"}`.

## Session and period privacy verification

Controller tests use real opaque session cookies through the Phoenix endpoint,
with sandbox-isolated identities/grants/work. They cover Owner/HR reads, explicit
shop scope, cross-tenant Owners (different people and the same person), profile
allowlists, current/former/rehire history, cursor isolation and stale-cookie denial.
After offboarding, the same old cookie cannot access terminated-business HR but
retains independently authorized other-business HR access. Rehire itself restores
no permission; even explicitly granted Employee access cannot read admin profiles
or prior-period history. Existing self-service period-isolation tests remain intact.

No Docker/Keycloak/browser server is required for these HTTP tests. Remaining
4F checks: browser/real-login cookie flows, future UI selector races and future
employee self-service HTTP APIs (none are added here). MFA/deployment hardening
remains required before production privileged access. Public booking and admin
appointment contracts are unchanged.

```sh
mix test test/scheduler_api_web/controllers/employee_controller_test.exs test/scheduler_api_web/controllers/admin_appointment_security_test.exs test/scheduler_api_web/controllers/admin_appointments_test.exs
mix precommit
```

See [protected HR write APIs](HR_WRITE_API.md) for the 4F-2 HTTP adapters,
session-bound CSRF requirements, payload allowlists and safe error contract.

See [HR_DIRECTORY_UI.md](HR_DIRECTORY_UI.md) for the 5C-1 read-only UI, privacy
boundaries and browser acceptance coverage.
