# Operational Admin dashboard — 5B

`GET /api/admin/businesses/:business_id/dashboard?shop_id=:shop_id` uses the
existing live browser session/private no-store boundary. Only `shop_id` is
accepted. Omit it for All Shops; that requires a current business-wide complete
operational grant. A collection of shop grants does not become All Shops.

Authorization resolves persisted account eligibility, membership/grant and tenant
status. One qualifying assignment must supply appointment-read, schedule-manage
and team-assignment permissions with the matching business/shop scope. Current
Owners and assigned Shop Managers qualify. Business Managers and Employees do not.
This composes existing permissions without creating roles or changing domain policy.
Unauthorized selectors return generic 403; missing/ineligible sessions 401;
malformed IDs/unknown fields 422. The existing private endpoint handles unexpected
failures without leaking SQL or data. GET does not need CSRF.

## Snapshot and definitions

A single SQL statement scopes authorized shops first, then calculates each shop's
local date from one UTC clock instant. Midnight and the next local midnight are
converted separately with PostgreSQL's configured IANA timezone rules. Days can
be 23/25 hours; All Shops uses each shop's own today, including UTC date crossover.
It is not a browser-local date or a fixed 24-hour UTC interval.

- **Appointments today:** starts in `[local midnight, next midnight)`, excluding
  cancelled; includes pending, confirmed and completed.
- **Awaiting staffing:** today's pending/confirmed appointments with zero active
  team members. Completed/cancelled rows never require staffing.
- **Active shifts today:** status active, overlapping the local day with strict
  half-open semantics (`starts_at < day_end`, `ends_at > day_start`), for active,
  effective employment and shop assignments. This includes earlier and later
  shifts today, not only employees currently on the clock. Cancelled/superseded
  shifts and ended employment/assignments are excluded.
- **Detailers scheduled:** distinct stable employee IDs classified Detailer among
  those shifts. Multiple shifts/jobs/shops cannot duplicate that person. Management
  classification and Employee role grants never imply Detailer status.

`data` contains `metrics`, minimal `shops` (id/name/timezone/date), and today's
`appointments`, ordered by UTC starts_at then id. Canceled appointments remain in
the list with their actual status. Fields: id, shop_name, timezone, starts_at,
duration_minutes, service_name, status, active crew_size, optional lead_detailer
(display name). No customer contacts, notes, price/pay, private HR, credentials,
provider metadata or audit objects are returned. Duration stays the appointment
snapshot; service name is associated catalog data. No totals derive from paginated
frontend results and team joins do not multiply appointment counts.

The bounded single-day list currently returns every authorized appointment today;
future pagination must retain server-calculated totals. Large tenant cardinality
and performance tuning remain future operational concerns.

## Frontend and verification

Dashboard renders only with operational capabilities; HR-only users get an explicit
no-scheduling-access message. The keyed business/shop view clears on selection,
logout or workspace refresh. AbortController and post-response abort checks discard
late responses; refresh clears old data before loading. 401/403/errors clear private
results. Shop-local times/date labels, responsive cards/list, semantic metric groups
and keyboard-accessible refresh use existing styling. No automatic idle-extending
polling, mutation, booking capacity or scheduling changes occur.

Tests cover complete totals/teams/leads, cancellation/completion, shop/business
isolation and All Shops, multi-shop distinct staff, Denver DST and half-open shift
boundaries, session/revocation HTTP denial, context replacement with out-of-order
responses and frontend failure states. Real-Keycloak acceptance adds an owned
operational fixture (pending/cancelled appointments, Detailer/shift/lead) and verifies
live totals, empty-shop switching, All Shops, mobile refresh and logout. Fixtures
remain in the isolated auth database and are cleaned with the existing runner.
