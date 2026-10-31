# Read-only Admin appointments/calendar — 5D-1

The old upcoming appointment/team endpoints remain unchanged: they cannot provide
past/cancelled local-day windows efficiently. New GET
`/api/admin/businesses/:business_id/calendar` supplies a minimal authorized read
projection for the Admin list, day agenda and bounded seven-day calendar.

## Request and scope

Required `date=YYYY-MM-DD`; optional `days=1|7` (default 1), `status=all|pending|
confirmed|completed|cancelled` (default all), `shop_id`, `limit=1..100` (default 50)
and bounded `cursor`. Unknown fields and malformed values return generic 422.
Missing/ineligible/expired/revoked sessions return 401; insufficient/foreign shop or
business scope returns generic 403. Existing private routing/no-store boundaries
apply; GET requires no CSRF. There is no new write route or migration.

The existing complete operational shop-scope query requires one current grant
supplying appointment read, schedule management and team-assignment permissions
with its own business/shop scope. Owners and assigned Shop Managers qualify;
Managers and Employees do not inherit operations. Omitted shop_id means All Shops
and requires a business-wide grant; a set of shop grants is not promoted into one.
Current user, membership/grant and business/shop eligibility are rechecked in SQL.
There is no default-shop fallback or client-selected tenant authority.

## Date, pagination and projection semantics

One SQL statement scopes shops first, computes each selected date's midnight and
next date/7-day endpoint using that shop's configured IANA timezone, converts those
boundaries explicitly to stored UTC, and selects appointment starts in the half-open
window. Days can be 23/25 hours. The selected calendar DATE is applied separately
in every shop's timezone; it is not one browser-local/UTC window. All Shops Today
navigation initially selects the first authorized shop's local date and labels that
reference timezone; other shops still use their own boundaries/display zones.

Status/window/scope precede UTC starts_at/id ordering and limit+1 keyset pagination.
Cursor binds actor, business, shop/All Shops, date, window and status, then UTC instant
and id. It is a position, never authority; every page recomputes current access.
No total appointment counts are inferred from pages. Calendar empty lanes say
"on this page"; partial-page notices and First/Next controls remain visible.

Response: `{data:{shops:[{id,name,timezone}],appointments:[...],meta:{has_more,
next_cursor,date,days}}}`. Appointment allowlist: id, shop_id/name, timezone,
starts_at/ends_at (explicit UTC Z ISO), snapshot duration_minutes, service_name,
vehicle_make/model/size, existing status, complete active crew_size, optional Lead
Detailer display name. End excludes the post-appointment scheduling buffer. Crew
aggregates are not limited by team pagination; DB uniqueness still ensures one
active lead. No customer contacts, notes, prices/pay, account/provider data or audit
objects are added. Read-only details use this same projection, not another unscoped
fetch. Pending/confirmed zero-crew appointments need staffing; completed/cancelled
ones do not. Catalog names remain associated catalog data.

## UI and boundaries

Chronological list, day agenda and week columns use native labeled date/status/view
controls, Previous/Next and Today actions. Shops have separate calendar lanes;
simultaneous cross-shop bookings are not conflict indicators. IANA zones and UTC
offsets are displayed (including changes across DST); no drag/drop or mutation exists.
Details focus their labeled panel and return keyboard focus to the triggering
appointment on close. Layout is responsive, with stacked mobile day/shop lanes.

Business/shop keys unmount and clear data/selection immediately. Filters/pages clear
old rows/details; AbortController plus post-response checks reject late responses.
401/403/errors remove private rows/details. Refresh uses current backend scope and
there is no idle-extending polling. Existing dashboard, HR/lifecycle and public
booking behavior and constraints are unchanged.

Tests cover real SQL authorization, cross-business/same-owner isolation, All Shops,
identical-time pagination, validated windows/statuses, complete two-person crews,
lead/canceled/zero-crew projection, session/revocation, Denver spring/fall DST and
New York versus Denver windows. Component tests cover timezone-separated lanes,
staffing labels, details, bounded queries, stale responses and failure clearing.
Real-Keycloak cases cover Owner/Shop Manager list/day/week/detail, one/zero crew,
lead, canceled filtering, date navigation, All Shops gating, mobile keyboard Today
and logout with disposable existing fixtures. Multiple-crew, multi-timezone and
pagination race evidence is backend/component coverage, not new real-browser claims.

Remaining: proportional time-grid layout, appointment mutations, exhaustive
accessibility audit and browser-level pagination/DST race combinations. Week view
is implemented as a bounded seven-local-date agenda; there is no unlimited history
fetch or calendar-provider integration. Production MFA/deployment hardening remains
separate.

## 5D-2 crew controls

Appointment details now include [authorized crew management](CREW_MANAGEMENT_UI.md)
for pending/confirmed appointments. Calendar date-window reads and public booking
remain unchanged; the existing team APIs own every mutation and audit.
