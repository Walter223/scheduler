# SchedulerApi

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Development verification

Run these scripts from any working directory (examples below are from the repository root):

- `./scripts/check-fast.sh`: formatting check, frontend lint and component tests; no browsers, servers or database setup.
- `./scripts/check-full.sh`: backend `mix precommit`, then frontend component tests, lint, build and anonymous Playwright, once each. Requires PostgreSQL, installed dependencies/Playwright Chromium, and free ports **4002/5174**. It refuses occupied ports and never stops services. Existing test aliases create/migrate only the test databases; Playwright owns and cleans its isolated fixtures. Do not run concurrently with other test runs sharing those databases.
- `./scripts/dev-smoke.sh`: read-only GETs of `/api/services` on **4000/5173**, validating and comparing backend/proxied catalogs. Start your normal dev services separately; this script never starts/stops anything.

Put the pinned runtimes (`mise`) and npm/Mix on PATH first. The full script forces
backend test mode and disables optional OIDC for anonymous checks. `mix precommit`
already compiles, formats and tests, and may remove unused lockfile entries; no
extra backend checks or dependency installation are added. Review resulting diffs.
The fast script is a feedback loop, not a replacement for full regression.

Real-Keycloak verification remains separate: from `frontend/`, run
`npm run test:auth` with **4000/5173 free**, Docker available, and the local auth
prerequisites in [AUTHENTICATION.md](AUTHENTICATION.md) satisfied. It uses isolated
test identities/data; do not stop user-owned servers or reset Keycloak to run it.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Availability

`GET /api/availability?date=2026-10-24&service_price_id=4` returns Denver-local
start times using the selected catalog duration. For a 90-minute service with
no blocking appointments:

```json
{
  "date": "2026-10-24",
  "service_price_id": 4,
  "duration_minutes": 90,
  "available_times": ["09:00", "09:30", "10:00", "10:30", "11:00", "11:30", "12:00", "12:30", "13:00", "13:30", "14:00", "14:30", "15:00", "15:30", "16:00"]
}
```

Dates must be Monday–Saturday, from today through today + 90 days inclusive,
using America/Denver's calendar date. Starts are every 30 minutes from 09:00;
the entire service plus a 30-minute buffer must finish by 18:00. Same-day
starts must be strictly later than now. A valid day with no slots returns
`200` with `available_times: []`.

Malformed/missing input, past dates, Sundays, and dates beyond the window return
`422`; unknown service prices return `404`. Errors have a stable code, field,
and message, for example:

```json
{"error": {"field": "date", "code": "closed_sunday", "message": "we are closed on Sundays"}}
```

PostgreSQL's IANA timezone rules handle Denver DST; timestamps on appointments
remain UTC. No new timezone package is required.

Each shop supports one appointment at a time across its service prices.
Pending and confirmed appointments occupy `[starts_at, starts_at + duration +
30 minutes)`. Cancelled and completed appointments do not block. Intervals that
only touch at their endpoints are allowed. Existing appointments use their
stored duration snapshots, even after catalog changes.

The GET result is informational. `Appointments.create_appointment/1` first takes
an exclusive transaction-level advisory lock for the selected shop, then
locks the selected catalog row for consistent snapshots, revalidates the requested
slot, and inserts in the same transaction. The next creator waits until commit or
rollback, then rechecks against the committed booking and returns a normal
`starts_at` validation error for an unavailable slot. This avoids deadlocks between
concurrent GiST exclusion checks. The advisory key is shop-specific; employee/bay scheduling is not implemented.
A partial GiST exclusion constraint remains the final safety net and rejects
overlapping active intervals within a shop even across concurrent database connections or
writes that bypass the context. Ecto maps conflicts to a `starts_at` changeset
error. Client price, duration, and status remain ignored.

Run `mix ecto.migrate` before using the engine. The migration also validates
existing active appointments: overlapping historical rows must be reviewed
before it can succeed; the migration does not silently change bookings.

`mix test` includes a real-concurrency test using independent SQL connections
and committed, isolated fixtures with cleanup. Public availability and booking endpoints retain their existing frontend contracts.


## Protected upcoming appointments API

`GET /api/admin/appointments` requires a valid Magnum browser session and the
code-owned `appointments.read` permission (`:appointments_read`). Missing,
expired, revoked or ineligible sessions receive `401 {"error":"authentication_required"}`;
valid sessions without an effective grant receive `403 {"error":"forbidden"}`.
All responses are `Cache-Control: no-store`. This read-only GET needs no CSRF token.

Business Owners can read active shops within their businesses; Shop Managers
can read explicitly assigned active shops. Business Managers, Employees and
login alone grant no access. Current account eligibility, membership/grant
lifecycle and business/shop status are checked server-side on every request.
One complete assignment must supply both permission and scope.

The list now covers the union of authorized shops rather than the configured
default shop. Ownership is joined from persisted records in SQL **before** upcoming
filtering, `(starts_at, id)` ordering and cursor pagination. Unauthorized rows
cannot affect page contents or metadata. `shop_id`, `business_id` and `user_id`
query selectors are rejected with 403; they cannot select authority. Cursors
remain positions, never authorization credentials. Internal default/explicit-shop
context functions remain available to trusted scheduling code; HTTP uses
`Appointments.list_authorized_upcoming_appointments(session, opts)` exclusively.

Mandatory staff MFA and production deployment hardening remain outstanding.

Optional query parameters:

- `limit`: integer from 1 through 100; defaults to 50. Larger values are rejected.
- `cursor`: the opaque `meta.next_cursor` from the preceding response. Pass it
  unchanged, URL-encoded. Pagination uses `(starts_at, id)`, not offsets.

Example from an authenticated browser's same-origin developer console:

```js
fetch('/api/admin/appointments?limit=25').then(response => response.json())
```

The `200` response contains `appointments` and `meta`:

```json
{
  "appointments": [],
  "meta": {"timezone": "America/Denver", "has_more": false, "next_cursor": null}
}
```

Each appointment contains `id`, `service_price_id`, `customer_first_name`,
`customer_last_name`, `customer_email`, `customer_phone`, `vehicle_make`,
`vehicle_model`, `service_name`, `vehicle_size`, `starts_at`, `duration_minutes`,
`price_cents`, `notes`, and `status`. Timestamps are UTC ISO 8601 strings (`Z`);
America/Denver is the display timezone. Service/size names reflect current
catalog associations; price/duration are the appointment's stored snapshots.
`notes` may be null. `has_more` indicates another page and `next_cursor` is null
on the final page. Each request uses the current server clock; pagination is
not a frozen snapshot. A client `now` parameter does not override that clock.

Malformed limits/cursors return `422`, for example:

```json
{"error": {"field": "limit", "message": "must be an integer from 1 to 100"}}
```

The listing does not apply availability business hours, buffers, Sundays, or
booking-window rules. Existing `POST /api/appointments` payloads, responses,
validation, pricing snapshots, and concurrency protection are unchanged.

## Stage 1 organization ownership

The organization migration creates one `Magnum Detailing` business
(`magnum-detailing`) and one `Magnum Detailing Default Location` shop (`default`),
with timezone `America/Denver`. No physical address is assumed. Lifecycle status
is `active` or `archived`; it is metadata in this stage, not a new booking rule.

Ownership is added nullable, backfilled, checked against a transaction-local
snapshot of every original row/field, and then made non-null with foreign keys.
IDs, timestamps, appointment snapshots, customer details, notes, and statuses are
preserved. Composite foreign keys keep shops, services, vehicle sizes, prices,
and appointments in the same business/shop. Catalog uniqueness is business-scoped;
service-price uniqueness is shop-scoped. Deleting referenced tenants is restricted.
The migration requires a reviewed rollback rather than silently discarding tenant
identity. Historical migrations are unchanged.

`Organizations.default_business!/0` and `default_shop!/0` resolve the known tenant
by stable slugs. Existing catalog creation assigns that tenant on trusted structs;
appointment ownership comes from its selected service price. Ownership is not
accepted from client attrs, and public request/response formats are unchanged.
Seeds can be rerun: they insert missing default catalog entries without overwriting
existing IDs, values, or timestamps.

## Coordinated shop-scoped scheduling

All public entry points resolve `Organizations.default_shop!/0` server-side using
business slug `magnum-detailing` and shop slug `default`. No first-row fallback or
request-supplied business/shop selection exists. The public catalog, availability,
booking creation, appointment lookup/listing, and admin listing use this boundary.
Services must have an offering in that shop; returned prices must match its shop,
business, service, and vehicle-size ownership. Foreign-shop price IDs produce the
existing missing-price errors. Ownership attrs cannot override the validated price.

Trusted internal callers can pass a persisted `Shop` explicitly to Catalog and
Appointments overloads and `Availability.get_for_shop/4`. These are business/data
boundaries, not authentication or authorization. HTTP controllers do not accept
that boundary from query/body params. Future authorization must resolve an allowed
shop before calling these functions. Queries filter shop/business before cursor
pagination; cursors remain positions, never access credentials. Names come from
the current catalog; appointment price and duration remain snapshots. Time/date
rules remain America/Denver in this milestone; other shop timezones are not enabled.

Each shop has one shared scheduling resource. The negative single-bigint advisory
key range is reserved for scheduling, with `key = -shop.id`. This is injective for
positive PostgreSQL bigint IDs, including IDs beyond 32 bits; no hash, truncation,
service price, customer, or user is involved. PostgreSQL's two-integer lock overload
only accepts 32-bit components. Other features must not reuse this negative key
namespace. The transaction acquires the shop lock before catalog `FOR SHARE`
locks, the authoritative availability recheck, and insertion. Future platform
access must use the same path and cannot bypass scheduling safety.

The new overlap migration installs `btree_gist` and changes the existing
`appointments_no_active_overlap` constraint to compare `shop_id WITH =` and the
same half-open occupied range (`starts_at` through duration plus 30 minutes).
Only pending/confirmed rows participate. Different shops may overlap; same-shop
active overlaps remain database errors even when the application is bypassed.
All prior foreign-key ownership consistency constraints remain in force.

**Deployment coordination:** drain/stop booking writers, run `mix ecto.migrate`,
deploy the matching application version, and resume writes. Old and new advisory
key schemes must not serve writes together. `btree_gist` installation requires
the appropriate database privileges. The migration holds an exclusive table lock,
adds the new constraint before dropping the old one, and retains the constraint
name in one transaction. There is no committed interval without overlap safety,
and appointment rows/IDs/data/timestamps are untouched. Allow time for constraint
validation/index building on a large table. Rollback to global scheduling fails
safely if cross-shop overlaps now exist; review data rather than deleting bookings.

The scheduling milestone did not add authorization. The admin listing now uses
the session and RBAC boundary described above; employee scheduling and frontend
shop selection remain out of scope.

## Account identity and session primitives

See [ACCOUNTS.md](ACCOUNTS.md) for the internal Accounts context, verified-identity
boundary, pending-user lifecycle, hashed revocable sessions and timeout policy.
These primitives add no login/session routes or application authorization and
work without Keycloak. Provider-token storage and OIDC integration are deferred.

## Membership and role persistence (RBAC Milestone 1)

`business_memberships` uniquely links a user/business with active/revoked lifecycle.
`role_assignments` stores one fixed role and complete scope: `business_owner` and
`business_manager` require NULL shop; `shop_manager` and `employee` require one
business-owned shop. Separate partial unique indexes prevent duplicate active
business and shop grants, including NULL scope. Composite foreign keys enforce
membership/business/shop consistency; all references use restrictive deletion.

No seeds, login paths or migrations grant membership/roles. New tables are empty.
The internal `Organizations.Memberships.revoke/2` and `reactivate/2` primitives
are persistence helpers, not authorized management APIs. Database triggers lock
membership rows for active grants and atomically revoke active assignments when
membership is revoked, including direct SQL revocation. Reactivation restores
membership only; revoked grants are immutable history, and any future regrant must
create a new row. Membership user/business and grant identity/scope are immutable.
Revocation records retain a timestamp, bounded reason and optional actor reference;
production audited workflows and last-owner protection are Milestone 2 work.

This adds no permission evaluator or protected API. Future checks MUST require
an eligible account, active membership, active business/shop and a single complete
active assignment that supplies both permission and matching scope. Never combine
roles/scopes across assignments. An archived tenant or a pending/suspended account
has no authorization merely because a grant exists. Employment relationships and
field-level personal-data permissions remain separate, unimplemented features.

God Mode is reserved for future separately controlled platform authorization with
strong MFA/step-up, audit and cross-tenant safeguards. It is not a customer role,
wildcard, seed or implicit access path. Existing admin APIs remain development-only.

Focused verification: `mix test test/scheduler_api/membership_persistence_test.exs
test/scheduler_api/membership_concurrency_test.exs
test/scheduler_api/membership_migration_test.exs` (one command). The migration test
runs up/down in a sandbox-owned schema and verifies existing row preservation and
zero automatic grants; concurrency fixtures use independent connections and clean
only their own rows. Rolling the migration back after real use removes RBAC
history, so production rollback needs review/export even though operational tables
are untouched.

## Authorization decisions (RBAC Milestone 2A)

`Authorization.authorize(user, action, resource)` returns `:ok` or
`{:error, :forbidden}`. Supported resources are persisted `Business`, `Shop`,
and `Appointment` references; their IDs are re-resolved, never their supplied
ownership/status fields. Unknown actions/targets and missing rows fail closed.
Caller identity must come from existing session authentication, not request IDs.
This context does not replace session validity, CSRF or tenant-specific context
validation, and it does not protect existing admin endpoints automatically.

`Authorization.permissions(role)` lists fixed policy names, not effective access.
Business Owners have the explicit business/HR/finance and shop-operation actions;
Business Managers have business-wide employment, compensation, payroll and finance
actions, but no access-management or shop operations. Shop Managers have shop
appointment, schedule, assignment, customer and operational actions only at their
assigned shops. Employee own/assigned actions and Shop Manager employee-specific
contact/compensation visibility are declared but always denied until employment
and job-record ownership resolvers exist. Broad compensation actions never grant
Shop Managers employee pay access. No permission enables payroll record storage,
role-management APIs or platform administration in this milestone.

`Authorization.authorized_shop_ids_query(user, action)` selects `%{id: shop_id}`
for supported shop actions. Compose it as a subquery into protected reads before
pagination; unknown/deferred actions produce an empty query. Grants, account
status/verified email, membership, business and shop status are evaluated when
SQL executes. One joined grant provides BOTH the action and matching scope;
no flattened roles/scopes, cookies, claims or cached allowlists are used.
Business-wide operations require a Business target; shop operations require a
Shop or supported record target. Appointment targets accept only appointment
read/manage actions; new resource types need explicit persisted resolvers.

These are current-statement decisions, not durable capabilities. Do not cache
materialized IDs or reuse an earlier `:ok` for a later write. Future sensitive
mutations must coordinate authoritative authorization/revocation checks with their
transaction/lock strategy. Field-level HR projections, protected controllers,
audited role changes and first-owner provisioning remain later milestones.

Focused checks: `mix test test/scheduler_api/authorization_test.exs`.

## Audited customer access changes (Milestone 2B-1)

Internal entry points in `Authorization.RoleManagement`:

- `grant_role(actor_credential, business, membership, role, shop \\ nil)`
- `revoke_role(actor_credential, business, assignment)`
- `revoke_membership(actor_credential, business, membership)`
- `reactivate_membership(actor_credential, business, membership)`

Actor credentials are existing inspect-redacted `Accounts.SessionCredential`
values, not user structs, user IDs or claims. A live session and eligible same-business
Owner assignment are verified inside every transaction using Authorization.
Targets are persisted schema references: membership identity and assignment scope
must match persisted values. Grant targets must be active, verified accounts with
active membership; shop grants require an active shop in the business. No operation
creates a membership, activates a user, bootstraps ownership or grants platform access.

All four operations lock the business row, then its member users (in ID order),
memberships and grants. Session rows are locked after account eligibility rows.
This serializes cooperating access changes and blocks account-status/grant changes
while authorization and the last-eligible-Owner check run. A last Owner cannot lose
their Owner grant or membership through these operations. Concurrent duplicate
grants return `:duplicate_grant`; repeated revocations/reactivations return existing
metadata with a `noop` event. Reactivation never restores revoked grants.

`authorization_audit_events` records only validated actor/target IDs, business,
membership/assignment, fixed role/shop, action, outcome, bounded reason and UTC time.
Membership revocation records its parent action and each cascaded grant revocation.
Foreign keys restrict history loss by cascading deletion. There is no public audit
mutation API, arbitrary payload or credential/profile field. Deployment database
privileges/retention must separately prevent unauthorized direct audit alterations.

Successful mutations and audit events commit together. Expected policy/input
rejections commit ONLY a denied event, returning `{:error, reason}`; never raise or
rollback merely to report those expected denials. Unexpected SQL/persistence errors
roll back the whole operation and return `{:error, :persistence_failed}`. An audit
outage therefore commits neither a grant change nor an unreliable success record;
a rejected attempt cannot be durably recorded while its audit storage is unavailable.
Outer caller transactions control final durability too: rolling back the caller
also removes its access mutation and audit events. Do not claim committed success
until the outermost transaction commits.

These are the required application-level management entry points. Older
`Organizations.Memberships` helpers and raw Repo writes remain trusted persistence
mechanics, not authorized/audited management workflows. No database can prevent its
privileged operator bypassing application policy. Global account suspension/recovery,
first-Owner provisioning, audited membership creation and protected HTTP APIs remain
separate workflows; do not route them through an unaudited production bypass.
God Mode remains separate and unimplemented.

Focused checks: `mix test test/scheduler_api/role_management_test.exs
test/scheduler_api/role_management_concurrency_test.exs` (one command). Tests use
isolated fixtures, direct audit-failure injection and independent-connection races;
no actual development identities receive access changes. The new audit migration
creates an empty table and does not rewrite existing records. Apply it before using
these operations; rollback drops audit history and requires an explicit retention
review once production events exist.

## First Business Owner bootstrap (Milestone 2B-2)

Deployment operators with authorized shell/deployment access and Magnum DB
configuration may explicitly run this task from `backend/`. Set BUSINESS_ID to
an existing business ID, OIDC_ISSUER to its exact configured Keycloak issuer,
and KEYCLOAK_SUBJECT to the exact existing Magnum user's immutable subject.
These are identifiers, not an email lookup or credentials. Never copy tokens or
client secrets into command arguments. Production uses the actual production
issuer/configuration; no production hostname is assumed here.

```sh
# Read-only dry-run: does not reserve ownership or write even an audit event.
env -u PHX_SERVER MIX_ENV=prod mix magnum.bootstrap_owner --business-id "$BUSINESS_ID" --issuer "$OIDC_ISSUER" --subject "$KEYCLOAK_SUBJECT"
# Explicitly apply after reviewing the dry-run and deployment approval.
env -u PHX_SERVER MIX_ENV=prod mix magnum.bootstrap_owner --business-id "$BUSINESS_ID" --issuer "$OIDC_ISSUER" --subject "$KEYCLOAK_SUBJECT" --apply
```

Use `MIX_ENV=dev` only for intentionally approved local provisioning. This is not
part of startup, login, migrations, seeds or HTTP. Apply the audit migration first.
Unset PHX_SERVER as shown; the command needs database access, not a new HTTP server.
No real development identities are provisioned by the tests or documentation.

`Authorization.OwnerBootstrap.run(business_id, issuer, subject, apply: false)`
is the task's internal implementation. It requires an existing active,
email-verified local user and active business. Unknown/pending/suspended/deactivated
identities are never created or activated. An existing membership must be active;
a revoked membership needs a separate reviewed process, not silent reactivation.
New membership creation and the fixed business-wide Owner grant occur only in apply.

The business row is locked using the same helper as RoleManagement. Eligibility
is rechecked under a user-row lock, then all Owner assignment history is checked
regardless of status/target. Any current or revoked Owner history blocks bootstrap
and requires a separate recovery process. Grant constraints remain authoritative;
no platform role, wildcard, alternative scope or email-based identity is accepted.
A new grant is also checked through the existing Authorization policy before commit.

Apply commits provisioning with an audit event whose source is
`deployment_operator_command`, action is `bootstrap_owner`, role is `business_owner`,
and actor_user_id is NULL. This truthfully identifies an invocation channel, NOT a
verified human operator. There is no operator-name flag or arbitrary asserted
identity. Deployment access control, approval and external operator logs must
identify the human; a person already holding privileged database credentials can
bypass application code, so this command is not protection against that operator.
Apply-mode expected denials commit only a bounded denied event; persistence/audit
errors commit nothing and return failure. Dry-run denials write nothing. Shell
output contains only bounded outcomes and local business/user IDs, never identity
claims, tokens or secrets. Existing audit records default to their original
customer-role-management source. Migration rollback refuses to discard/mislabel
bootstrap audit history once events exist.

Focused checks: `mix test test/scheduler_api/owner_bootstrap_test.exs
test/scheduler_api/owner_bootstrap_concurrency_test.exs` (one command). These use
sandbox fixtures and positively owned, cleaned test rows only. No actual development
accounts receive memberships or privileges. Protected admin APIs, owner recovery,
activation/invitations, verified operator attestation and God Mode remain separate.

## Parallel anonymous Playwright

`npm run test:e2e` defaults to **2 workers**. CLI overrides remain supported, e.g.
`npm run test:e2e -- --workers=1` or `--workers=4`. Global `fullyParallel` remains
false: the six catalog, selection, validation, availability, booking and conflict
specs run concurrently across files; tests within each file remain sequential.
The same isolated Phoenix/Vite servers and `scheduler_api_test_e2e` database are
used, with existing no-reuse/port protections. Do not run separate suite invocations
concurrently against that database. Real-Keycloak `test:auth` is unchanged/separate.

Global setup seeds the source-controlled catalog once and marks it with a fresh
invocation UUID. An owner-commented, UUID-named PostgreSQL sequence allocates unique
per-test dates, independent of worker number. Monday–Saturday base dates occupy
alternating weeks, reserving each test's following-week date too. Up to 36 test
allocations fit inside the booking horizon; exceeding capacity fails explicitly.
No scheduling rule, API or retry policy changes are required.

Per-test teardown closes its page and deletes only appointments on that allocated
date referencing this invocation's marked prices. It cannot delete another test's
date or shared catalog. Global teardown runs after workers finish and removes only
this invocation's catalog, appointments, allocator sequence and temporary manifest;
foreign-reference guards remain. Failures are not hidden by retries or sleeps.
A forcibly killed run can leave owned fixtures: inspect the preserved manifest in
an OS temp `magnum-anonymous-e2e-*` directory and use `MIX_ENV=test
MIX_TEST_PARTITION=_e2e mix run --no-start scripts/e2e.exs cleanup RUN_UUID`
from `backend/` only after its workers stop. Never delete broadly by name/prefix;
cleanup validates the exact UUID's sequence ownership and catalog marker. Existing
unowned catalog names cause setup to refuse overwriting data. No migration or
reset is involved in allocator creation/removal.
