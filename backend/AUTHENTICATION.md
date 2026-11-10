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
on PATH. The runner requires free **4002/5174**, never stops or reuses 4000/5173,
and runs exclusively against `scheduler_api_test_auth_e2e`. It creates a temporary
confidential Keycloak client with exact localhost:5174 callback/origin and a fresh
memory-only secret; magnum-web and normal production/development configuration
remain unchanged. Eight owned Keycloak identities cover active/pending login and
Admin roles. Accounts are mapped by exact issuer/subject only; explicit test grants
and tenants exist solely in the isolated database. All nine browser cases use real
Keycloak forms, authorization codes and signed tokens, never a login bypass.
Fixtures are mode-0600 temporary files; traces/screenshots/video are disabled.
Owned client/users, account/session/login/RBAC/employment fixtures and managed
servers are cleaned in finally. See [ADMIN_CONTEXT.md](ADMIN_CONTEXT.md) for the
complete isolated-origin security contract, scenarios and results.
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

## Local host-process launcher

`python3 scripts/dev-backend.py --check` (from the repository root) validates that
ignored `infra/auth/.env` can supply the confidential client secret without printing
it or starting anything. `python3 scripts/dev-backend.py` starts Phoenix in development
on port 4000 with the canonical issuer, magnum-web client and exact localhost:5173
origin/callback. It refuses an occupied port and never stops another process.
Stop an existing development backend only with its owner's explicit approval.
The running backend does not automatically pick up environment changes; a launcher
cannot enable OIDC in an already-running auth-disabled process. Vite need not restart.
This launcher does not activate users, provision grants or change production policy.

### Explicit local operator activation exception

For the personally requested local Admin setup, the operator may activate only
an explicitly approved existing pending identity in `MIX_ENV=dev` against
`scheduler_api_dev`, after rechecking the local magnum realm account is enabled,
email-verified and free of required actions. Resolve the synchronized Magnum user
by the exact canonical issuer and Keycloak subject, never by email alone. Recheck
pending/verified state under a user row lock and call `Accounts.set_user_status/3`;
do not create an HTTP activation endpoint or relax normal callback eligibility.
This is a one-account operator action, not an automatic signup/activation policy.
Suspended/deactivated or unrelated identities are excluded. Accounts has no separate
activation-audit primitive; first-Owner provisioning uses the existing durable,
audited `magnum.bootstrap_owner` dry-run/apply workflow and all ownership-history
checks. Production restrictions and isolated browser-test behavior are unchanged.

## Explicit new-business signup exception

6A-2A adds signup-purpose OIDC transactions and separate browser-bound onboarding
proofs. Pending accounts receive no normal session and ordinary login remains
unchanged. Activation is atomic only with successful creation of a new tenant.
See [BUSINESS_PROVISIONING.md](BUSINESS_PROVISIONING.md#6a-2a-implemented-self-service-boundary)
for routes, cookies, CSRF, limits, audit provenance and deployment migration.

## Local login reachability and recovery

From any working directory, run `python3 /absolute/path/to/scheduler/scripts/dev-auth-health.py`
(or `python3 scripts/dev-auth-health.py` from the repository root). This read-only
check probes listeners 4000/5173, direct/proxied `/api/me`, canonical realm discovery,
and the launcher's secret-safe configuration check. It prints no response bodies,
secret values, cookies or provider credentials. It does not call `/auth/login`,
create login transactions, sign in, migrate, start or stop anything. Exit 1 means
at least one prerequisite failed. Presence of launcher configuration does not prove
running provider readiness or validate the client's secret against Keycloak.

`ECONNREFUSED 127.0.0.1:4000` is a TCP listener failure before OIDC or Phoenix routing.
Check the backend process first; do not reset Keycloak or change callback settings
in response. If port 4000 is free and the operator wants to start development,
`python3 scripts/dev-backend.py` starts the documented OIDC-enabled backend in the
foreground. It refuses occupied ports. Starting/replacing user-owned services
still requires authorization; no health check automatically repairs processes.
Then rerun the health check and sign in via `http://localhost:5173/admin`.

The ordinary retry link retains `/auth/login`, but first performs a five-second,
read-only same-origin `/api/me` probe. Refusal, proxy errors, malformed replies or
timeout preserve the React page/business selector with a recovery message. No
OIDC URL is fetched as a preflight and no automatic redirect/retry loop is added.
A server can still fail between probe and navigation; this check reduces that race,
it cannot guarantee reachability. Keycloak/provider failures retain existing safe
callback errors. Signup's separate OIDC purpose and pending denial are unchanged.

Isolated browser acceptance includes an actual stop/start of the runner-owned
Phoenix child on 4002 via temporary-directory IPC (`bff_backend_control.py`). Only
the parent holding the Popen handle can signal/recreate that process; no arbitrary
PID input or production test-control HTTP endpoint exists. The helper requires
the dedicated test partition and owned fixture directory. Development ports and
services are never targeted. Existing role, revocation, expiry, Signup, HR, Calendar
and tenant-isolation tests run after/alongside this fault/recovery scenario.

## Development schema and backup safeguards

The launcher now checks the **effective** development Repo connection using
`scripts/dev_preflight.exs` without booting Magnum. Only `scheduler_api_dev`, user
postgres, standard port 5432 and loopback host/server address are permitted. CI,
non-dev MIX_ENV, DATABASE_URL overrides, remote/socket targets and unknown applied
migration versions fail closed. No credentials or raw configuration are printed.
The launcher always injects opt-in OIDC and requires the existing ignored secret;
this does not change environment/configuration of an already-running process.

- `python3 scripts/dev-backend.py --check`: read-only database/schema/config check;
  occupied port allowed, no backup/migration/start.
- `python3 scripts/dev-backend.py`: start only when schema is current and 4000 free.
- `python3 scripts/dev-backend.py --migrate --confirm-database scheduler_api_dev`:
  explicit local migration authorization followed by startup. Review pending files
  first; port 4000 must be free. Stop a user-owned backend only with permission.

Opt-in writes a custom `pg_dump` archive under `.local/backups/` (git ignored,
private directory and 0600 archive), verifies full `pg_restore` decoding without
restoring a database, and writes SHA-256 plus preservation manifests. Only then
can normal `mix ecto.migrate` run. All original tables/columns are fingerprinted
before and after; additive default columns are excluded from the original-row
comparison. Backup/migration/preservation failures leave the server unstarted and
backup retained for review. There is no automatic reset or rollback. A populated
security-history migration may intentionally disallow rollback.

Normal read-only startup does not scan row contents. Data fingerprints are used
only for explicitly requested backup/migration verification. Backups contain
private application data and protocol material: never publish/commit them.
`pg_dump`/`pg_restore`, local PostgreSQL, Mix and the pinned runtime must be available.
No user activation, grants, provisioning or catalog seeding occurs in preflight.
