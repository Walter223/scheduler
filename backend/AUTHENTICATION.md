# Browser authentication boundary (Milestones A and B)

Keycloak authenticates identity. Phoenix authorizes Magnum access. Browser login,
callback, revocable opaque sessions, session-bound CSRF, status and local logout
are implemented. Authentication grants **no business/shop authorization**.
`/api/admin/appointments` now requires a valid browser session and current
`appointments.read` authorization, with database-level business/shop scoping.
Login alone grants no access. Private responses are not cached or captured by
the development request logger. See [README.md](README.md#protected-upcoming-appointments-api).
Mandatory staff MFA and production privileged-access hardening remain outstanding.

## Dependencies and transport

Direct `oidcc` 3.9.0 is pinned; Mix resolved JOSE 1.11.13 and
telemetry_registry 0.3.2. OIDCC Plug is unnecessary because Magnum owns its
PostgreSQL transaction model outside Plug.Session. OIDCC's maintained default
HTTP transport (`httpc`) is intentionally retained per this milestone's explicit
instruction; Req remains the application HTTP client elsewhere. Requests have a
five-second timeout. No custom HTTP adapter is installed. Authorization (including
OIDCC automatic PAR) and token exchange explicitly select `client_secret_basic`
to match magnum-web’s Keycloak client-secret authenticator; realm-wide advertised
JWT authentication methods do not imply this client accepts them.

OIDCC 3.9.0 fixes CVE-2026-75759 (encrypted unsigned ID tokens). JOSE 1.11.13
addresses the advisories published October 26, 2026. Recheck advisories whenever
resolving/upgrading dependencies. The preceding maintenance milestone upgraded Bandit to 1.14.0, Thousand Island
to 1.6.0, HPAX to 1.1.0 and Plug Crypto to 2.2.1. Deferred findings remain in
Decimal, Mint, Phoenix LiveView and Postgrex; the graph is not advisory-free.

## Optional provider

By default `MAGNUM_OIDC_ENABLED` is absent/false and no discovery worker starts.
Normal tests and anonymous booking require neither Docker nor Keycloak.

To enable the provider in an explicitly configured host process, supply:

- `MAGNUM_OIDC_ENABLED=true`
- `OIDC_ISSUER` (development default: `http://auth.magnum.test:8080/realms/magnum`)
- `OIDC_CLIENT_ID` (`magnum-web` only)
- `MAGNUM_WEB_CLIENT_SECRET` (secret environment injection; never source-control/log)
- `MAGNUM_APP_ORIGIN` (development default: `http://localhost:5173`; explicit HTTPS origin required in production)
- `OIDC_REDIRECT_URI` (development default: `http://localhost:5173/auth/callback`)

The backend does not automatically read `infra/auth/.env`. Do not print or copy
its values into documentation. Callback must equal the explicit application
origin plus `/auth/callback`; request Host/forwarded headers never select it.

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
only approved return path is `/admin`; all other values are rejected.

`consume_login_transaction(state, binding, now: utc_datetime)` hashes bounded,
canonical presented values and locks the matching unconsumed/unexpired row.
Consumption and clearing nonce/verifier happen atomically. Exactly one concurrent
consumer receives inspect-redacted `ConsumedLogin` exchange material. No DB lock
is held across provider exchange. Exchange failure intentionally burns the attempt;
the caller must begin again. The HTTP layer delivers/checks a temporary
HttpOnly browser-binding cookie. These credentials cannot be
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

## Browser routes and cookies

- `GET /auth/login`: fixed return `/admin`, `openid profile email`, no offline access
  or forced fresh SSO login. Creates a new independent binding each time.
- `GET /auth/callback`: consumes state + binding **before** code exchange. Denial
  consumes the matching transaction too. Synchronizes immutable issuer/subject,
  then issues a fresh credential only for active, email-verified local users.
- `GET /api/me`: `{authenticated, user, csrf_token}` with minimal local profile,
  or `{authenticated: false, user: null, csrf_token: null}`. Always no-store.
- `POST /auth/logout`: authenticated, exact-origin, masked-CSRF checked. Returns
  `{ok: true}`, durably revokes the local session and clears both cookies. An
  absent/invalid session returns 401 and clears a stale credential cookie.

Development uses `magnum_session_dev` and `magnum_login_dev`; production uses
`__Host-magnum_session` and `__Host-magnum_login`. All are HttpOnly, SameSite=Lax,
Path=/, no Domain. Secure is mandatory except the exact local development HTTP
origin. The session cookie is a browser-session cookie; DB idle/absolute deadlines
remain authoritative. Login binding expires in 600 seconds. A later login replaces
that cookie: older tabs cannot complete their callbacks and must start again.
Their unconsumed server rows expire normally. Success revokes any previous valid
Magnum credential before delivering the new one. Nothing upgrades the binding.

Unknown users stay pending without a Magnum session. Suspended, deactivated and
unverified identities receive the same bounded account-unavailable response.
There is no activation endpoint, email-based merging or automatic authorization.

## CSRF and activity

`web_sessions.csrf_state` stores Plug-generated unmasked CSRF state, redacted from
inspect and SQL write logging. Existing sessions initialize it lazily under row
locks. `SessionCSRF` uses the supported Plug `load_state`, `dump_state`,
`get_csrf_token`, and `valid_state_and_csrf_token?` APIs, isolating process-local
state after each operation. React receives only masked tokens, kept in memory.
No custom token cryptography or second Plug session cookie is introduced.

Authenticated mutations require `x-csrf-token` and an exact configured Origin.
Only a missing Origin permits a Referer fallback with an exact literal authority
boundary; null, duplicate, foreign or malformed origins fail. Cross-session CSRF
fails. Revocation/blocked accounts fail session lookup before CSRF, and revocation
clears stored CSRF state. New sessions receive fresh state. Public anonymous
booking routes deliberately do not use this authenticated mutation pipeline.
Future authenticated mutation routes must opt into both session and CSRF plugs
and independently enforce context-level authorization.

Status requests never touch idle expiry, and the UI does not poll continuously.
No authenticated business operations exist yet. Future meaningful authenticated
activity may call the existing capped `Accounts.touch_session/2`; absolute expiry
must never move. Authentication is not authorization.

## Same-origin development and production

Vite proxies `/auth` and `/api` to `http://127.0.0.1:4000` by default; browser API
calls are relative. `MAGNUM_API_UPSTREAM` is a Vite server-only override used by
isolated anonymous E2E (4002). It is not a browser credential or trusted public
origin. Production must route both paths to Phoenix under one explicit HTTPS
application origin, preserve Set-Cookie, and forward only trusted proxy metadata.
No production hostname has been chosen. BFF routes do not enable credentialed CORS.

Before local login, start auth infrastructure and run
`python3 scripts/auth.py reconcile-callback`. This updates only magnum-web's
exact callback, explicitly retaining empty webOrigins (Keycloak otherwise derives
origins during the partial update). Startup import does not reconcile existing
realms. No reset, signing-key rotation or user deletion is involved.

## Logout, provider lifetime and production limitations

Logout is **Magnum-local** and succeeds while Keycloak is unavailable. Keycloak
SSO may remain active, so another login may complete without a password prompt.
Provider tokens are discarded, with no refresh, RP logout or backchannel logout
implementation. Remote Keycloak disablement/session termination does not currently
revoke a live Magnum session; local suspension/revocation is immediate. A Magnum
session can otherwise persist until its idle/8-hour absolute deadline. Profile
sync occurs on login. This propagation gap, required staff MFA, HTTPS/passkeys,
authorization and admin endpoint protection must be resolved before privileged
production use. No memberships, invitations, God Mode or MFA flows were added.

## Logging, errors and retention

Auth responses are no-store with no-referrer; callbacks redirect to `/admin` or a
bounded `auth_error` code without callback parameters. No external assets are
served on callback responses. Phoenix parameter filters include code/state/nonce,
verifier/token/secret/cookie/authorization. Router parameter logging and Dashboard
request capture are disabled for auth/status routes; authentication dispatch
errors do not render the development debugger or raw exception details. SQL writes
containing protocol/CSRF secrets are not logged. Do not export telemetry `conn`,
headers, provider error bodies or unfiltered query strings. Configure reverse
proxy/access logging to omit callback queries and cookie/authorization headers.
Logging infrastructure review remains a production deployment prerequisite.

Expired login rows can be purged with `delete_expired_login_transactions/1`;
arrange cleanup within 24 hours operationally. Session history retention/scheduled
cleanup remains a policy decision; no scheduler or destructive production purge
was added. Consumed nonce/PKCE secrets clear immediately.

## Verification and controlled successful-login workflow

Normal `mix test` requires no Keycloak. Protocol tests use real signatures and
OIDCC validation; HTTP-boundary tests use an isolated signed-token provider.
`npm run test:e2e` retains all anonymous workflows on `scheduler_api_test_e2e`.

For real Keycloak integration, from `frontend/` run `npm run test:auth` with Docker
on PATH. Stop your ordinary 4000/5173 dev servers first; the runner refuses occupied
ports. It uses the exact browser origin/callback, real Keycloak forms and signed
tokens, and `scheduler_api_test_auth_e2e` exclusively. It creates two randomly
named temporary Keycloak identities with verified fixture emails and strong random
passwords, activates only the corresponding **issuer/subject-mapped test user** in
the isolated DB, and proves pending denial for the other identity. No roles are
granted and no production login bypass exists. Fixtures live in a mode-0600 file
in an OS temporary directory; browser traces/screenshots/video are disabled to
avoid recording credentials. Owned users, sessions and login rows are removed in
finally cleanup. No existing realm users or development application data are used.
Do not manually activate real users merely to demonstrate login; use this runner
until the invitation/activation policy is implemented.

Next: authorization/invitation design plus a separate remote-revocation/MFA
hardening milestone before production staff/customer-data access. Do not treat
this browser boundary as permission to expose the current admin API.

## Hidden account entry

`/admin` is a minimal frontend account-entry page (loading, signed out, login
error/retry, signed in and local logout). It has no public navigation link and
fetches only `/api/me`, never privileged admin data. Public pages do not mount
account controls or read auth error codes. Phoenix retains `/auth/login` and
`/auth/callback`; success and bounded failures return only to `/admin`. Caller
return parameters are ignored; context and DB allow only `/admin`. The additive
return-path migration maps existing fixed `/` metadata to `/admin` without
changing credentials, expiry or consumption. Apply migrations before deployment.
Production must serve the frontend for direct `/admin` loads while proxying
`/auth/*` and `/api/*` to Phoenix. No Keycloak callback URI changes are needed.
This page proves identity only and grants no business/shop permission.
