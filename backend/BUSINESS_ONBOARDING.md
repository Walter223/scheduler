# Business onboarding draft foundation — 7A-1

API-only progress/resume interface; no concierge/frontend wizard or applied setup
operations. Signup and ordinary Owner login are unchanged. One shared schema-v1
private draft per business is created on demand, never during GET or login. Only
currently active/verified users with a complete active business-wide Owner grant
can read or mutate it. Multiple current Owners collaborate on the same draft;
creator identity is provenance, not a permanent grant. Revoked Owners lose access.

`B=/api/admin/businesses/:business_id/onboarding`:
- POST B with empty JSON: begin or resume the same draft.
- GET B: retrieve progress (404 if not started).
- PUT B: full allowlisted proposal replacement with `revision`, UUID `request_id`,
  `state`, `proposal`, optional boolean `confirm_review`.

Existing browser-session authentication, session-bound CSRF/exact origin checks on
writes, 64KB JSON bound and no-store handling apply. Safe errors: 401 invalid
session, 403 unauthorized, 404 not started, 409 revision/request conflict, 422
validation/transition failure, 503 persistence failure. IDs are selectors only.

Ordered states: provisioning_complete → locations → employees → services_pricing →
branding → review → ready_to_publish → completed. Same-state saves and one-step
backtracking are supported; completed is terminal. Advancing past Services requires a valid proposed
service catalog; ready/completed require `confirm_review=true`. Empty employees supports
solo operators. Empty location proposals retain the separately exposed applied
first shop; no shop is ever created or duplicated by this workflow.

Proposals require locations, defaults, employees, services and branding, with an
optional versioned catalog extension described below.
7A-1 location entries use a stable draft key, name, IANA timezone, in_shop operating
model and optional same-business active existing_shop_id. Defaults are reserved
and empty. Employees are bounded proposed names/contact/intended roles and location
keys, never accounts, invitations, employment records or RBAC grants. Legacy services use
integer cents/minutes; branding only a display name and validated hex color.
Unknown fields (including credentials/roles/ownership/status injection), invalid
references, excess counts and invalid timezone/type/range values are rejected.
Do not enter passwords/provider credentials in any proposal text.

Every decision is live and transactional: business lock, existing ordered member/
user/grant locks, session lock and eligibility recheck, then draft mutation. A
unique business index prevents duplicate drafts. Revisions reject lost updates.
Durable actor/draft/UUID receipts bind the full request hash: exact retries return
the original revision, changed reuse conflicts, and retries never reapply writes.
Clients must not replace a newer local revision with an older retry response.
Each accepted revision (including same-state saves) writes an atomic metadata-only
audit event; proposals are not duplicated into audits. Audit failure rolls back
both draft and receipt. Restrictive FKs preserve history; no purge/delete API.

Applied business/shop metadata is a separate response projection. Nothing in a
proposal is dispatched into Repo, RoleManagement, HR, catalog or scheduling. Draft
completion means reviewed proposal only. Responses always say published=false
and list unapplied-configuration/publication blockers. There is no public-booking
change, publication switch or assertion that travel-aware scheduling exists.

Future AI boundary: accept structured, versioned proposed edits through the same
allowlists/revision checks. AI text/tool output is untrusted and grants no access.
Phoenix must validate persisted scope and explicit human confirmation before each
sensitive application operation. Never convert arbitrary draft keys to tool names,
permissions, atoms, SQL or account operations. Separate reviewed apply commands
must implement idempotency, authorization and auditing per domain.

Future UI reports actual persisted draft revision and validated steps. Application
jobs must expose real accepted/running/failed/applied status and blockers, rather
than artificial timers, simulated build progress or publication claims. Applying
locations, invitations, services, assets and publication requires later milestones.

Deployment requires the additive add_business_onboarding_drafts migration; it adds
empty draft/audit/receipt tables and no tenant backfill or implicit configuration.
No development migration was executed. No frontend or live-Keycloak test is needed
for this API-only milestone; session/OIDC integration is unchanged and protected
HTTP tests use real isolated sessions/CSRF and persisted grants.

## Multi-location and mobile draft extension — 7A-2

Integrated only after the 7A-1 backend and real-Keycloak checkpoint passed. This
is an additive schema-v1 proposal extension, not applied shop/scheduling settings;
no further migration is needed. The original base validation profile is retained
as a private module documenting the narrower 7A-1 contract.

Location proposals support `key`, optional same-tenant active `existing_shop_id`,
`name`, optional `address`, `timezone`, `operating_model` and `mobile`. Models:
`in_shop`, `mobile`, `both`. Use the provisioned first shop's ID from the separate
`applied.shops` response; it is never inserted again. Stable unique keys distinguish
planned additions. Duplicate keys and repeated existing shop IDs are rejected.
Omitting an applied shop from the proposal does not delete or archive it.

`defaults` accepts timezone, operating_model and mobile settings. Location timezone/
model may inherit defaults; explicit overrides win. The server adds a read-only
`effective_locations` projection to responses so clients need not invent merge
rules. Mobile objects merge by field; service-area arrays replace, never union.
A local `dispatch_source=this_location` clears an inherited dispatch-location key;
an explicitly contradictory local key is rejected.

Mobile fields: `service_areas` (up to 20 descriptive areas, each <=200 bytes),
`dispatch_source` (`this_location` or `location_key`), optional
`dispatch_location_key` referencing a key in this draft, and
`travel_buffer_minutes` (integer 0..240). These are proposals, not geographic
polygons, routes, guarantees of address coverage, or recursive dispatch execution.
Timezone names use the PostgreSQL timezone catalog. Addresses are bounded plain
text (1000 bytes), not geocoded or externally verified. No external network calls.

Partially specified addresses/mobile setup may be saved at any editable step.
Forward transitions beyond Locations revalidate the current proposal, including
late edits, and require an address for every explicit proposed location and nonempty areas,
dispatch source and travel buffer for mobile/both models. Existing omitted shops
remain applied records, not implicitly configured by defaults. Empty employees is
valid for solo operators and unstaffed shops. Collection bounds: 20 locations,
100 employee/service proposals; unknown fields and credentials are rejected.

Every inherited/overridden value and existing-shop reference is validated inside
the same Owner-authorized, business-first transaction. Draft retries and concurrent
edits use the same receipts/revisions as 7A-1. Interrupted sessions resume from the
persisted proposal; no provisioning or domain writes occur on save/resume.

Follow-up: reviewed shop application with audited identity reconciliation, physical
address verification policy, hours, geocoded service areas, dispatch-resource and
travel-aware capacity/availability, and explicit publication gates. **Public mobile
booking remains unavailable.** Existing booking buffers, staffing authorization,
shop locks and capacity rules are unchanged.

## Staff proposals — 7A-4

Draft schema_version remains 1 (JSON extension, no database migration). Each new
employee proposal has `version: 2`, stable `key`, `name` (full name), `email`,
`classification`, `location_keys`, `responsibilities` and `access_roles`.
Required fields cannot be omitted; an empty employees array explicitly supports
solo/no-staff businesses. Work emails use a conservative ASCII mailbox/domain
syntax; blank/whitespace, malformed domains and case-insensitive duplicate emails
are rejected. Names need not be unique: two real people can share a name. Keys
must be unique. No identity is looked up or linked by email.

Classification is exactly detailer/shop_manager/business_manager/business_owner.
It does not imply an employment record, membership or role. Responsibilities are
`{business_management: boolean, shop_management_keys: [location_key]}`. They express
untrusted business HR/finance/shop-management intentions, not effective authority.
Shop-management keys must be included in that person's proposed shop assignments.

`access_roles` is an explicit list of `{role, location_keys}` requests: Employee
and Shop Manager require nonempty shop scope drawn from the person's assignments;
Business Manager requires an empty location_keys array (business scope). Duplicate
roles, Owner/platform/wildcard requests, unknown fields and mismatched scopes fail.
The same person may request independently scoped roles without merging permission
and scope. Zero access requests and temporarily unassigned employment are allowed.
A manager classification holding an Employee request remains management-classified;
future compensation privacy must enforce persisted classification/history as usual.

Existing/proposed locations share stable draft keys; rename/reorder does not alter
staff references. Deleting a referenced location or removing an assignment while
retaining scoped requests fails validation until references are explicitly cleared
or reassigned. Nothing cascades into actual employment, jobs, schedules or RBAC.

Older name/email/intended_role proposals remain readable and historical receipts
are not rewritten. The editor presents them in the v2 shape for explicit completion:
missing email/classification requires user input, never inference from a role.
Existing intended access is displayed as a request; classification is not inferred.
New saves require the complete v2 contract. No automatic development-data backfill
or silent activation/grant is introduced.

The existing business-first Owner/session checks, revision compare, UUID receipts,
atomic metadata audits and field-bounded private JSON handling apply unchanged.
Future invitation/application must separately reauthorize targets/scopes, enforce
Owner protection and employment eligibility, audit actual writes and confirm them.
Draft review is neither an invitation nor authorization to execute those writes.


## Services & Pricing proposals — 7A-5A

The optional `catalog` JSON extension is `{version: 1, currency: "USD",
vehicle_categories: [{key, name}]}`. Names are business-specific, trimmed, bounded
and case-insensitively unique; keys are stable lowercase/hyphen identifiers.
Up to 20 categories and 100 services are supported within the existing 64KB request
bound. No migration, active catalog mutation, tenant copying or development
backfill occurs. Existing schema_version=1 and stored receipts remain unchanged.

New service entries have exactly `version: 2`, `key`, `name`, `description`,
`duration_minutes`, `status`, `delivery_mode`, `location_keys`, `prices`, `overrides`.
Names/descriptions are required (255/2000 bytes). Durations are integer 1–1440
minutes; estimated service duration may be explicitly overridden by shop. Status
is `active` or `planned`, describing intended offering only. Modes are `in_shop`,
`mobile`, `both`. Every service requires at least one existing/proposed location
key and at least one vehicle category. Service names and keys are unique.

`prices` supplies one shared `{category_key, price_cents}` for every category.
USD cents must be exact positive integers, at most 100,000,000, matching active
catalog positive-price semantics. Missing, duplicate, fractional/string or orphaned
prices fail validation. `overrides` contains at most one object per offered shop:
`{location_key, prices, duration_minutes?, delivery_mode?, status?}`. Its price
array may override a subset of categories; omitted values inherit shared defaults.
No implicit array union, other-tenant catalog lookup or reference by name occurs.
Effective delivery must fit each shop's effective draft operating model: a `both`
shop permits any mode; a single-mode shop permits only its matching mode.
Removing categories/locations requires explicitly resolving all affected references.

Legacy three-field services remain readable and accepted without `catalog` for
compatibility. The editor adapts them in memory with a visible Standard category,
preserves their cents/duration and requires explicit description/shop completion
before saving the new shape. Legacy entries do not satisfy Services completion until explicitly upgraded.
Historical receipts and database JSON are not rewritten.

Empty services/categories may be saved to defer configuration. They do not satisfy
`readiness.services_configured` or a forward transition to Branding/Review. Same
revision/idempotency/Owner/session/audit rules apply. Generic suggestion text has
no inherited prices or shop availability. No status or review state publishes a
service; **mobile booking is unavailable** until separate travel-aware scheduling
and explicit enablement exist.

Future AI proposals must use this same structured contract, reference this draft's
stable keys and pass Phoenix validation and Owner review. Applying service/vehicle
identities, shop-specific price/duration snapshots and publication needs a separate
audited workflow; no onboarding field invokes Catalog or scheduling operations.

## Branding drafts — 7A-5B

Branding accepts display_name (255 bytes), optional tagline (200) and description
(2000), contact_email (254), contact_phone (7–15 digits, optional leading + and
spacing/parentheses/hyphens), primary_color/secondary_color/accent_color (six-digit
hex) and preset (modern/premium/minimal). Unknown fields and asset URLs fail.
Partial valid drafts can be saved; Review requires every field except optional
text. readiness.branding_configured is server-derived. Existing revisions, receipts,
Owner/session checks and metadata-only atomic audits apply. No migration is needed.

The scoped preview uses escaped React text, validated CSS colors and fictional
service cards with no booking links or availability. Mobile/desktop preview modes
are illustrative. Logo is a placeholder, never an arbitrary URL or upload. Future
uploads require authorized tenant-owned storage, bounded size/type validation,
decoding/re-encoding, malware checks, safe serving and audited asset references.
Custom palette contrast requires review before publication. No live website or
platform identity changes. Screenshots: /private/tmp/magnum-branding-onboarding/
with preset-{1440,1024,768,390,320}.png, validation.png, mobile-preview.png and
review-320.png; successful acceptance runs archive these automatically.
