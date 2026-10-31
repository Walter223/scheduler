# Protected compensation APIs — 4F-4A

Prefix `B=/api/admin/businesses/:business_id`;
`P=B/employees/:employee_id/periods/:period_id/compensation`.

| Method/path | Access / contract |
|---|---|
| GET `P/current` | Authorized HR current pay, or assigned Shop Manager's permitted current Detailer pay |
| GET `P/history` | HR-only, effective-dated history, including retained ended periods |
| POST `P/rates` | Existing authorized `Compensation.set_rate` workflow |
| GET `B/me/compensation/current` | Authenticated actor's own authorized current-period pay; no target-user selector |

Every route uses the current opaque browser session and no-store responses. Writes
use existing session-bound CSRF (`GET /api/me` then `x-csrf-token`), exact Origin/
controlled Referer validation and the private 64 KB JSON parser. No frontend,
role-management, payroll or schema migration is introduced.

Stable employee and exact period IDs are separate, validated against persisted
business relationships and compensation authorization scopes. Current grants,
account eligibility and tenant/shop status are re-evaluated, not cached in cookies.
A current-read permission is not history or write permission. Owners are business-
scoped; HR Managers cannot access current/historical protected Owner pay. Shop
Managers see only current active assigned Detailers and no management-history pay.
Historical classification protection follows stable identity across rehire, in
addition to existing Owner/management role history. Classification grants nothing.

Employee access is exclusively through own-current, with explicit linked identity,
complete grants and active current-period shop relationships. Termination removes
that access; rehire restores no grants/rates. Old open-ended pay remains attached
to its ended period. HR retains separately authorized history access. Existing
period-private self-service rules and conservative management-pay restrictions
are unchanged.

## Requests, projections and pagination

POST accepts only `amount`, `pay_basis`, optional `currency`, `effective_from` and
optional `effective_until`. Example:

```json
{"amount":"25.50","pay_basis":"hourly","currency":"USD","effective_from":"2026-11-02"}
```

Exact decimal strings or integers are accepted; floating-point JSON numbers,
fractional cents, nonfinite values and unsupported fields are rejected. USD,
hourly/annual_salary, date/chronology and immutable-history rules remain entirely
in the domain. No client ownership/status/actor/user/audit fields, retroactive
correction, scheduled-rate cancellation or deletion workflow is exposed.

Current/create responses: `{"data": rate_or_null}` (201 for creation, 200 reads).
A rate includes only `rate_id`, `business_id`, `employee_id`, `period_id`,
`pay_basis`, `currency`, canonical two-decimal string `amount`, `effective_from`,
`effective_until`. Authorized absence is `data:null`; no notes, contact/profile,
provider/session or audit fields appear. Whole schemas are never serialized.

History: `{"data":{"rates":[],"has_more":false,"next_cursor":null}}`.
Accepts only `limit` 1..100/default 50 and bounded `cursor`. Complete authorization
and period/tenant scope precede effective_from/id ordering and keyset pagination.
Cursor encodes period ID, effective date and rate ID; it is a position, not a grant.
Cross-period/malformed cursors return 422, and unauthorized rows never influence
items or page metadata. No unbounded history list is exposed through HTTP.

Error JSON is bounded: 401 `authentication_required`; generic 403 `forbidden`;
existing CSRF/origin 403 errors; 422 `invalid_input`; 409 `effective_date_conflict`
or `employment_ended`; 503 `operation_unavailable` on audit/database failure.
No salary values, provider data or SQL exception details enter errors. Domain
transactions preserve prior rates/closures and roll back on audit failure.

## Verification and remaining gaps

Cookie/CSRF HTTP tests cover the role matrix, historical/reclassified/rehired Owner
protection, shop restrictions/multiple shops, period/tenant spoofing, own-current,
termination/rehire isolation, precise money/date conflicts, history pagination,
private-field exclusions and financial audit rollback. An independent-connection
HTTP race proves same-date writes yield one rate and one safe 409 without duplicates.
Existing independent-connection financial/domain race tests remain unchanged in
behavior; the HTTP case reuses their isolated owned-fixture lifecycle.

Remaining: real Keycloak/browser tests; HTTP own-pay after effective rehire plus
explicit new grants (domain tests cover that isolation); concurrent HTTP
classification/offboarding/pay combinations. No UI or production MFA readiness
claim is made. Development data is never migrated or used by test fixtures.

```sh
mix test test/scheduler_api_web/controllers/compensation_controller_test.exs test/scheduler_api/compensation_concurrency_test.exs test/scheduler_api/compensation_test.exs
mix precommit
```
