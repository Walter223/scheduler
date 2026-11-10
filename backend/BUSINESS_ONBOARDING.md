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
backtracking are supported; completed is terminal. Review requires a proposed
service; ready/completed require `confirm_review=true`. Empty employees supports
solo operators. Empty location proposals retain the separately exposed applied
first shop; no shop is ever created or duplicated by this workflow.

Proposals have exactly locations, defaults, employees, services and branding.
7A-1 location entries use a stable draft key, name, IANA timezone, in_shop operating
model and optional same-business active existing_shop_id. Defaults are reserved
and empty. Employees are bounded proposed names/contact/intended roles and location
keys, never accounts, invitations, employment records or RBAC grants. Services use
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
