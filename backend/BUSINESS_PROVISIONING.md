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

## Original boundary decisions before 6A-2 (superseded below)

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

## 6A-2A implemented self-service boundary

The approved exception permits verified pending accounts to become active **only
inside successful new-business creation**. Ordinary login and operator bootstrap
retain their existing eligibility policies. No frontend signup screen is included.

Flow (same configured application origin and callback; no Keycloak change):

1. `POST /auth/signup/login` with an empty JSON object and exact Origin (or the
   existing controlled same-origin Referer fallback) starts a `signup`-purpose
   login transaction. Normal `GET /auth/login` always records `login`. Purpose is
   server-persisted, never accepted in callback/browser identity claims.
2. Existing `GET /auth/callback` consumes state and browser binding before provider
   exchange. Unchanged OIDCC signature/issuer/audience/nonce/PKCE/expiration checks
   establish the immutable identity. Only a validated signup callback may call
   `Onboarding.issue_after_oidc`; the supplied User is an internal trusted value,
   not a public identity constructor. Account state is reloaded under lock.
3. Eligible pending/active verified identities receive two separate HttpOnly,
   SameSite=Lax, Path=/, no-Domain ten-minute cookies: `magnum_onboarding_dev` and
   `magnum_onboarding_binding_dev` (Secure `__Host-` counterparts in production).
   Proof and browser binding are independently generated through the OIDC flow;
   only their hashes are persisted. No pending-user session or operator capability
   is issued. The clean callback destination is `/admin?signup=ready`.
4. `GET /auth/signup` returns only a masked Plug CSRF token for the matching proof
   and binding. `POST /auth/signup/business` requires both cookies, that token in
   `x-csrf-token`, exact same-origin validation, and the strict business/shop JSON
   shape above. Parsing is bounded to 64 KB outside request telemetry. All signup
   responses are no-store. Failures expose only safe errors, never provider detail.
5. Completion locks proof then user, checks live verification/eligibility, applies
   creation limits, and atomically activates that pending identity, creates the
   independent tenant through shared provisioning internals, records a truthful
   `self_service_signup` audit with actor=target and `activated_pending_account`,
   and consumes the proof with the exact request hash and result. All changes,
   including activation and successful-creation counters, roll back on failure.
   No normal session is created; after success ordinary login can issue one.

Proof validity is strictly before its ten-minute expiry. Concurrent identical
submissions return the same result; a different payload after consumption fails.
Retries are limited to the proof lifetime and cannot restore revoked grants.
Failed validation, slug collision or audit insertion leaves proof and pending
status retryable. Cookie theft alone is insufficient without the independent
browser binding and proof-specific CSRF token. Browser-provided owner/role/user,
existing-business, membership and status fields are rejected. There is no operator
issuer endpoint. Suspended/deactivated/unverified accounts fail even with an old
proof. Keycloak outages fail login safely and cannot produce a new proof; an
already validated proof can finish while the provider is unavailable.

Concurrent login attempts keep independent server records until expiry; the most
recent callback replaces the browser's delivered cookies. There is no cross-proof
mutation under a user lock (avoids inverted proof/user locking). Browser switching
without both cookies fails. Successful creation is limited across all proofs for
one identity, not just the latest browser attempt.

Conservative PostgreSQL-backed fixed-window limits: 20 signup POST attempts per
socket IP per 15 minutes, five proof issuances per identity per UTC hour, and one
successful new business per identity per UTC day. IP attempts commit before body/
proof validation so rejected submissions count; successful idempotent retries do
not consume the creation budget. Database UPSERTs serialize limits across nodes.
Window boundaries allow adjacent-window bursts. Production requires trusted proxy
IP configuration (never arbitrary forwarded headers), ingress/login rate limits,
capacity monitoring, abuse policy and retention/purge of expired proofs/counters.
Current code uses the actual socket IP; a proxy can group clients conservatively.
Identity limits do not replace protection against many new Keycloak identities.

Deployment: apply the additive `add_self_service_onboarding` migration before
running updated code. It adds login purpose, onboarding proofs, shared limits,
intent/audit provenance and activation metadata. Existing rows default to ordinary
login/operator provenance; no accounts are activated by migration. Rollback of
retained security history requires review. No development migration was run.

### 6A-2B browser integration

The customer UI lives at `/signup`; successful signup callbacks now return there
instead of the earlier `/admin?signup=ready` marker. Validated signup cancellation/
provider errors also return a generic error there. Unknown/invalid transactions
retain the existing safe authentication fallback. `/auth/signup/login` returns
`{redirect_to: authorization_url}` only for explicit `Accept: application/json`,
so the UI navigates to Keycloak without cross-origin fetch redirect handling.
Normal redirect callers and every authorization/proof check remain unchanged.
See [frontend signup verification](../frontend/SIGNUP.md).

### Persisted post-login setup

[Business onboarding drafts](BUSINESS_ONBOARDING.md) provide an Owner-only API to
begin, save and resume proposed setup after ordinary login. Draft completion is
separate from provisioning, domain application and publication; it grants nothing.
