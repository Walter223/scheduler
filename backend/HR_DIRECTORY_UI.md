# Employee directory and employment history UI — 5C-1

The Admin Employees and HR area is read-only. Current server capabilities select
one of two modes, never frontend role labels or employment classifications:

- Business `employees`: Owner/authorized Manager business-wide Active/Former
  directory, latest profile, retained timeline and explicit period profiles.
  The scope is explicitly business-wide even when the shell has a selected shop.
- Selected-shop `roster`: current assigned-shop contact roster only; no Former
  Employees, generic profile or employment timeline controls. Shop Managers receive
  this existing contact permission in discovery without gaining HR authority.

Employees and signed-out users receive no directory navigation. All REST endpoints
still authenticate and authorize every request, including after revocation. The
`roster` discovery hint is presentation only; tampering with selectors/mode does
not authorize a different endpoint. No hiring, edits, lifecycle, compensation,
account, role or scheduling mutations are exposed by this UI.

## Queries and projections

Existing HR read endpoints are reused. Directory and shop roster gain optional
`q` (literal case-insensitive first/last-name substring, up to 100 UTF-8 bytes) and
`classification` (fixed existing classifications). SQL authorization, latest-period
selection and active/former filtering precede search, ordering and bounded keyset
pagination. UI page size is 20; backend remains bounded 1..100. Cursors additionally
bind search/classification when present; old unfiltered cursor contracts remain.
Filtering is server-side, not restricted to rows already loaded in the browser.

Contact projections gain `shops`: only id/name/status/start/end dates for the exact
period. HR sees that period's retained assignments at active business shops; shop
roster sees only current effective assignments at its authorized shop, never other
shops or ended relationship history. Timeline rows remain contact-free. No pay,
provider/user identifiers, sessions, raw audit records or unrestricted schemas are
serialized or displayed. Nullable business contacts have no Keycloak fallback.

Stable employee ID drives directory/profile/timeline paths. Exact period ID is
used only under that stable identity to fetch a chosen period. Original/ended and
subsequent rehire periods remain distinct. Historical addresses/contacts appear
only in the separately authorized selected-period profile, never inferred or copied
into current records. Rehire does not restore grants, employment data or history
access for Employees. The UI displays lifecycle status and effective dates, not an
invented lifecycle workflow or inferred permission.

## State and accessibility

Business/shop changes remount and clear directory, filters, cursors, selected
profile and period. AbortController plus post-response guards discard late responses.
Changing views/search/pages closes the old profile. Failed/revoked/expired reads
clear prior contact data and display bounded messages. Status polling is not added.
Search, classification, view and pagination controls are labeled native inputs and
buttons. Profile opening focuses its labeled region; closing returns focus to its
trigger. Responsive cards/contact definitions and timelines reuse Admin styling.

## Verification boundaries

HTTP tests cover Owner/Manager HR, Shop Manager-only contacts, Employee/anonymous
and stale-session denial, distinct/same-human Owners, rehire periods, safe identifiers,
private-field allowlists, literal search, classification, filter-bound cursors and
shop projection isolation. Component tests cover query controls/pagination, history
IDs, no-pay rendering, stale out-of-order responses and 401/403/error cleanup.
Real-Keycloak acceptance extends the isolated runner with former and rehired staff,
Owner/Manager timeline browsing, historical-contact separation, and mobile scoped
Shop Manager rosters. Existing dashboard and anonymous booking suites remain intact.
Historical fixture creation is confined to the guarded auth-test database; no real
employee lifecycle records or development identities are modified.

Remaining scope: no editable forms, self-service UI, exhaustive accessibility audit,
production MFA hardening, or browser-level race tests for concurrent HR mutations.

5C-2A adds [authorized everyday HR forms](HR_MANAGEMENT_UI.md) to the existing
read views. `hr_manage` explicitly gates controls; historical views and Shop Manager
rosters remain read-only. Existing HR authorization and retained-period privacy
continue to govern all requests.
