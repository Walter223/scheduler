# OIDC protocol foundation (Milestone A)

Keycloak authenticates identity. Phoenix authorizes Magnum access. This milestone
adds protocol/persistence primitives only. Browser login is **not functional**:
there are no auth routes, cookies, CSRF integration, `/api/me`, activation,
memberships, or authorization. The admin appointments endpoint remains
unauthenticated, development-only, and not production-safe.

## Dependencies and transport

Direct `oidcc` 3.9.0 is pinned; Mix resolved JOSE 1.11.13 and
telemetry_registry 0.3.2. OIDCC Plug is unnecessary because Magnum owns its
PostgreSQL transaction model outside Plug.Session. OIDCC's maintained default
HTTP transport (`httpc`) is intentionally retained per this milestone's explicit
instruction; Req remains the application HTTP client elsewhere. Requests have a
five-second timeout. No custom HTTP adapter is installed.

OIDCC 3.9.0 fixes CVE-2026-75759 (encrypted unsigned ID tokens). JOSE 1.11.13
addresses the advisories published October 26, 2026. Recheck advisories whenever
resolving/upgrading dependencies. Resolution also reported existing advisories
on unchanged Bandit, Decimal, Mint, Phoenix LiveView, Plug Crypto, and Postgrex.
Those were not silently upgraded or treated as resolved by this milestone.

## Optional provider

By default `MAGNUM_OIDC_ENABLED` is absent/false and no discovery worker starts.
Normal tests and anonymous booking require neither Docker nor Keycloak.

To enable the provider in an explicitly configured host process, supply:

- `MAGNUM_OIDC_ENABLED=true`
- `OIDC_ISSUER` (development default: `http://auth.magnum.test:8080/realms/magnum`)
- `OIDC_CLIENT_ID` (`magnum-web` only)
- `MAGNUM_WEB_CLIENT_SECRET` (secret environment injection; never source-control/log)
- `OIDC_REDIRECT_URI` (development default: `http://localhost:4000/auth/callback`)

The backend does not automatically read `infra/auth/.env`. Do not print or copy
its values into documentation. That callback is reserved, not implemented.
Milestone B must coordinate its browser-origin change with realm configuration.

`Config.new/2` permits HTTP only in development for the exact canonical local
issuer and callback. Other environments require HTTPS. URLs cannot contain
userinfo, query, or fragment. Issuers never originate from request parameters.

The OIDCC worker initializes asynchronously and retries discovery/JWKS failures
with random exponential backoff bounded to 1–30 seconds, rather than its default
stop-on-error behavior. `Provider.context/0` returns `:auth_disabled` or
`:provider_unavailable` cleanly. Worker state contains no client secret; trusted
configuration/context must never be logged. Authentication outages do not gate
public application startup. Provider-dependent features must check readiness.

## One-time login transactions

`Authentication.create_login_transaction(config, now: utc_datetime)` returns an
inspect-redacted `LoginAttempt`. `Credential.reveal/1` is an explicit delivery
boundary, not permission to log values. State, nonce, PKCE verifier, and browser
binding each originate from **independent 32-byte secure random values**,
serialized as canonical unpadded Base64URL (43 characters). S256 is required;
providers advertising only plain PKCE are rejected.

PostgreSQL stores only SHA-256 of serialized state and binding. Nonce and verifier
are bounded server-side fields until consumption. Issuer, client, and exact
callback are snapshotted; changed configuration invalidates protocol use. The
only approved return path is `/`; all other values are rejected.

`consume_login_transaction(state, binding, now: utc_datetime)` hashes bounded,
canonical presented values and locks the matching unconsumed/unexpired row.
Consumption and clearing nonce/verifier happen atomically. Exactly one concurrent
consumer receives inspect-redacted `ConsumedLogin` exchange material. No DB lock
is held across provider exchange. Exchange failure intentionally burns the attempt;
the caller must begin again. The later HTTP layer must deliver/check a temporary
HttpOnly binding cookie; this milestone issues none. These credentials cannot be
upgraded to Accounts sessions; Accounts independently generates session tokens.

Lifetime is exactly ten minutes; equality with `expires_at` is expired. Explicit
UTC clocks normalize to whole seconds. `delete_expired_login_transactions/1`
purges expired rows on demand. No scheduler is installed. Expired rows should be
purged within 24 hours operationally; consumed protocol secrets clear immediately.

## Protocol and identity trust boundary

`Protocol.authorization_url/3` builds code + S256 requests with state/nonce and
`openid profile email`. It returns a sensitive URL for future redirect delivery;
never log that URL. `Protocol.exchange_code/5` takes only committed consumption
material and trusted provider configuration/context. Its only successful output
is `Accounts.VerifiedIdentity`, never the provider token response.

OIDCC validates signatures, exact issuer, client audience, nonce, expiration,
not-before, and authorized party. Magnum restricts signing to RS256, disables
ID-token encryption and extra audiences, and never disables authorized-party
validation. `magnum-api` is not the ID-token audience. OIDCC max clock skew is zero;
protocol operations fail closed if that setting changes.

**After successful OIDCC validation**, the private identity adapter independently
requires `now < exp`. Equality and later instants are rejected before constructing
VerifiedIdentity. No OIDCC code is patched. Structurally invalid email, subject,
verification boolean, profile names, authentication time, or issuance time are
rejected. Subjects remain opaque and unchanged. Missing provider `auth_time`
remains nil; Accounts' fallback synchronization timestamp is not assurance proof.
`email_verified=false` remains false so Accounts can enforce eligibility.

The public token-validation primitive performs real OIDCC verification and accepts
no claims-map shortcut. Only the private post-validation adapter constructs the
OIDC-facing VerifiedIdentity. This is an internal typed boundary, not protection
against trusted BEAM code deliberately constructing structs. Synchronization and
session issuance remain explicit Accounts operations; pending users stay pending.

Access/refresh/ID tokens exist transiently during exchange and are discarded. No
provider-token columns, vault/encryption dependencies, credentials, or real users
are added. Errors return bounded categories rather than token-bearing OIDCC terms.
Do not attach telemetry/log handlers that dump raw provider error bodies/claims.

## Verification and next milestone

Focused tests: `mix test test/scheduler_api/authentication`.
They exercise real JOSE signatures and OIDCC validation, encrypted-unsigned-token
rejection, deterministic strict expiration boundaries, a local HTTP token endpoint
using the default transport, provider outage, and ten independent-connection
consumption races. Normal tests require no Keycloak and create no real users.

Milestone B must implement login/callback, fresh Accounts cookie issuance, local
POST logout, CSRF, minimal `/api/me`, same-origin frontend proxy/fetch integration,
and exact coordinated Keycloak redirects together. Include provider-unavailable
handling and secret-safe request/access logging. Preserve pending-user policy and
provider-token non-persistence. Authentication alone must grant no admin access.
