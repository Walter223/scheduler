# New-business provisioning — 6A-1

`SchedulerApi.Provisioning` is an internal domain service, not signup, activation,
an HTTP endpoint or permission to claim an existing tenant.

## Trusted caller and API

Only explicitly authorized deployment-operator/server code may call
`authorize_operator(issuer, subject, attrs, opts \\ [])`. Deployment access is the
authority; supplied identity strings are selectors, never authentication or proof
of operator identity. **Never expose this issuer through a controller, callback,
job accepting untrusted identity parameters, or ordinary authenticated request.**
Like the existing operator bootstrap, this boundary trusts code/deployment access;
it does not defend against arbitrary trusted BEAM code or database administrators.

The exact immutable issuer/subject must identify an existing active, email-verified
Magnum user. No email lookup, account creation, status change, employment creation,
implicit role grant on login or existing-business selector is supported.

The exact request shape is:

```elixir
%{
  business: %{name: "Independent Detail", slug: "independent-detail"},
  shop: %{name: "Main Shop", slug: "main", timezone: "America/Denver"}
}
```

All extra fields are rejected, including ownership, status, roles and catalog
settings. Existing changesets validate nonblank names, bounded strings and slugs;
PostgreSQL's timezone catalog validates the configured IANA timezone. Business
slugs are globally unique; shop slugs are business-scoped. Display names remain
nonunique by the existing tenant model: a matching name never establishes ownership.

Issuance returns `{:ok, %Provisioning.Credential{}}`, a redacted 256-bit random
capability bound to the persisted owner and exact request. Only SHA-256 of its
canonical unpadded Base64URL serialization is stored. Treat it as secret; never
log it, put it in URLs/browser storage, or reuse an Accounts session credential.
Issuance creates only the intent; it does not create a tenant or grant.

`provision(credential, opts \\ [])` returns `{:ok, %{business_id, shop_id,
membership_id, role_assignment_id, audit_event_id}}`. An uncompleted intent is
valid for ten minutes, strictly before expiry. `now: utc_datetime` is an internal
deterministic test seam; no HTTP clock override exists. The production clock is
read after lock waits. Invalid inputs/credentials, ineligible identities, expired
intents, slug collisions and persistence failures return bounded error atoms.

## Atomicity, concurrency and existing ownership

Provisioning locks the capability row, then reloads/locks the owner and rechecks
eligibility. All subsequent inserts and completion commit together: a **new**
active business, first active shop, active membership, exactly one business-wide
Owner grant, and one `provision_business` authorization audit. The audit truthfully
uses `deployment_operator_command`, with no invented human actor; target is the
verified owner. Its shop identifies the created shop; the Owner grant itself has
NULL shop scope. Audit failure rolls back the entire attempt and leaves the
pre-issued intent unconsumed. No external call occurs under locks.

The intent is the idempotency key. Concurrent identical calls serialize on its
row and return the same committed IDs. Completed retries remain retrievable after
the issuance deadline, with current account eligibility checked. They never mutate
membership/grant state, restore revoked access or constitute authorization to use
the returned resources. A new credential is a distinct authorized request.
Database business-slug uniqueness arbitrates distinct concurrent requests; the
loser receives `slug_unavailable`, never the winning tenant's IDs or access.

There is no existing-business lookup/claim/reuse path. Existing membership/grant
history, Owner recovery and last-eligible-Owner protections are untouched. Existing
Owners can receive a separate explicit intent for another independent business.
Creation touches only the intent, its owner lock and newly inserted tenant rows;
the new business is not externally visible until commit, so it cannot participate
in existing-business lock cycles. Later management uses the existing business-first
locking and current persisted RBAC checks.

## Safe initial state and preservation

No catalog, prices, appointments, customers, employment or data from Magnum is
copied. There are no shop-hours/publishing settings to inherit. The initial shop
has only explicit name/slug/timezone and active internal status. It is **not
published**: public APIs still resolve only the existing configured Magnum default
shop, and no public tenant route or discovery is added. Active internal status is
not permission to publish. A future public tenant resolver must add explicit
publication gates and per-shop booking policies before exposing these shops.

The additive migration creates an initially empty intent table with restrictive
FKs, unique capability/result indexes, completion/expiry/hash/name checks and
composite shop/membership ownership FKs. It extends audit action/source checks
without rewriting existing rows. Rollback refuses to erase any retained intent or
provisioning audit; populated production rollback requires a reviewed history plan.
No development migration, seeds, public defaults or operational rows are changed
by this milestone. Completed intents/audits are retained; no purge job is added.
Rejected preflight attempts return safe errors; they do not promise a durable
denied audit. Database/audit failures cannot record themselves durably.

## Required boundary before 6A-2

Do not call the operator issuer from self-service signup. A separately reviewed
issuer must verify live authenticated identity, explicit create-new-business
consent, account eligibility and abuse/creation limits, then bind a one-time proof
to that identity and exact intent. For verified **pending** users, normal sessions
remain forbidden. Decide the narrowly scoped onboarding proof, browser binding,
CSRF/origin protections, expiration/replay handling and explicit new-business-only
activation policy first. Suspended/deactivated identities must not gain a recovery
bypass. Any activation/session issuance and new audit source must accurately
reflect that future workflow; this operator path never activates accounts.

Future HTTP input must never choose an arbitrary owner or existing tenant, accept
an operator label as authority, or derive claims from names, email or domains.
Publication, invitations, billing, branding, MFA/deployment hardening and tenant
recovery remain separate. This milestone introduces no new production auth policy.
