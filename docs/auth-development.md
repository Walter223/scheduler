# Local Keycloak development foundation

**Keycloak authenticates identity. Phoenix authorizes Magnum access.** Keycloak
groups/roles must never become the source of truth for Magnum business/shop
permissions. The `master` realm administers Keycloak; it is unrelated to future
Phoenix-owned God Mode. Business Super Admins are not Keycloak administrators.

This milestone is infrastructure/configuration only. There are no Phoenix login,
callback, session, user, membership or authorization handlers and no React login
UI. Anonymous booking runs without Docker/Keycloak. `/api/admin/appointments`
remains unauthenticated and development-only; starting Keycloak does not secure it.

## Versions and boundaries

Verified against official documentation on 2026-10-27:

| Service | Exact image | Reason |
| --- | --- | --- |
| Keycloak | `quay.io/keycloak/keycloak:26.8.1` | Current stable community release, including October security fixes |
| Auth PostgreSQL | `postgres:18.6` | Supported PostgreSQL 18 series, current published maintenance release |
| SMTP sink | `axllent/mailpit:v1.32.0` | Maintainer image; current release includes email-rendering security fixes |

These are exact version tags, not floating tags. Production should also record
verified multi-architecture image digests and review security updates regularly.
Community Keycloak is not a commercial support subscription or an LTS promise.
No application dependencies are upgraded or added.

Root `compose.yaml` contains only services in profile `auth`, project
`magnum-auth-dev`. Phoenix/React and their database stay outside Compose. The
dedicated internal `auth` network isolates database connectivity. Keycloak and
Mailpit additionally use the `auth-local` bridge, required for Docker Desktop to
forward published ports. PostgreSQL never joins that bridge. Only loopback host
ports 8080 (Keycloak), 9000 (local management)
and 8025 (Mailpit UI) are published. Auth PostgreSQL/SMTP publish no host ports.

## Prerequisites and first bootstrap

Install/start Docker Desktop or a compatible Docker Engine with Compose v2
supporting `up --wait`; Python 3.9+ is used for dependency-free helper commands.
If Docker Desktop is installed but `docker` is not on PATH, prefix helper
commands with `PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"`.
This affects that command only; no system or shell configuration change is needed.
From the repository root:

```sh
python3 scripts/auth.py init
```

This creates **ignored** `infra/auth/.env` with random database, bootstrap and BFF
client secrets, mode 0600. It refuses to overwrite an existing file. The example
is documentation only; do not reuse placeholder values. Never paste rendered
`docker compose config` output into tickets: it contains resolved secrets.

Add this line once to your machine's `/etc/hosts` (requires host administrator
permission; the scripts do not change system files):

```text
127.0.0.1 auth.magnum.test
```

Then:

```sh
python3 scripts/auth.py check
python3 -m unittest discover -s scripts -p 'test_auth.py'
python3 scripts/auth.py config-check
python3 scripts/auth.py up
python3 scripts/auth.py smoke
```

Equivalent direct startup, with the same project/env boundary:

```sh
docker compose --project-name magnum-auth-dev --env-file infra/auth/.env --profile auth up -d --wait --wait-timeout 240
```

Open `http://auth.magnum.test:8080/admin/`; use the local bootstrap credentials
from the ignored file. Keep those credentials local. Bootstrap administration is
only for local infrastructure setup/testing, never for Magnum application users.
Keycloak bootstrap variables create an initial administrator on an empty DB;
changing them later does not rotate an existing administrator. Do not expose this
development deployment remotely.

## Persistence, restart and deterministic source changes

Keycloak uses database **keycloak**, role **keycloak**, its own random password,
and project volume `magnum-auth-dev_auth-postgres`. PostgreSQL 18 data is mounted
at `/var/lib/postgresql`. Keycloak owns all its tables/migrations. Phoenix must
never query or migrate them. No Scheduler DB URL/credentials are supplied here.

Mailpit stores captured mail in `magnum-auth-dev_auth-mail`, limited to 500
messages. It has no relay/forwarding configuration. No real email is sent.

`infra/auth/magnum-realm.json` is the source of truth. `--import-realm` imports
`magnum` on first bootstrap, **skipping an already existing realm**. Restarts do
not reconcile changes to realm JSON or a changed client secret in `.env`.

```sh
python3 scripts/auth.py status
python3 scripts/auth.py logs
python3 scripts/auth.py stop
python3 scripts/auth.py up
```

Stop/up preserves local identities, sessions, keys, realm settings and mail. For
an intentional rebuild from the current source configuration:

```sh
python3 scripts/auth.py reset --destroy-local-auth-state
```

This checks the fixed project/service boundary, the running local Docker Desktop
target, actual Compose resource ownership labels and foreign resource consumers,
then runs Compose `down --volumes`,
then starts and smoke-tests a fresh import. It destroys **all local Keycloak
state**, including master administration, users, sessions, signing keys, and
captured mail. It preserves `.env`. It cannot drop `scheduler_api_dev`, backend
test databases or application tables. Do not use generic Docker volume-prune
commands. The script has no configurable project/database target.

Prefer source edits followed by this explicit local reset. If experimenting in
the Admin Console, translate intended changes into reviewed realm JSON, strip
all users/keys/secrets, run source checks and validate a clean rebootstrap before
committing. Console-only state is not a deployment specification. Do not commit
raw exports. Do not run offline override imports against a running server.

## Canonical OIDC contract

Exactly one issuer is accepted by the future application:

| Purpose | URL |
| --- | --- |
| Issuer | `http://auth.magnum.test:8080/realms/magnum` |
| Discovery | `http://auth.magnum.test:8080/realms/magnum/.well-known/openid-configuration` |
| Authorization | `http://auth.magnum.test:8080/realms/magnum/protocol/openid-connect/auth` |
| Token | `http://auth.magnum.test:8080/realms/magnum/protocol/openid-connect/token` |
| JWKS | `http://auth.magnum.test:8080/realms/magnum/protocol/openid-connect/certs` |
| End session | `http://auth.magnum.test:8080/realms/magnum/protocol/openid-connect/logout` |
| Future Phoenix callback | `http://localhost:4000/auth/callback` |
| Future logout return | `http://localhost:5173/` |

Callback/logout URLs are reserved contracts, **not implemented routes**.
`KC_HOSTNAME` is explicit and backchannel dynamic hostnames are disabled. The
browser and host Phoenix process use the hosts entry. A future container can
resolve the same name through the auth network alias at the same port; it must
not use a different issuer such as `http://keycloak:8080`. Future full deployment
must deliberately connect authorized services to this network or use a proxy.

HTTP is local-development-only (`sslRequired: none`). `auth.magnum.test` is not a
browser secure context over HTTP, so realistic WebAuthn requires a later trusted
local HTTPS proxy/certificate. Keep the DNS name/RP ID; changing HTTP to HTTPS
changes the issuer and requires a coordinated configuration/identity-mapping
migration once local users exist. Do not silently accept multiple issuers or
auto-link accounts by email. No such persisted users exist yet.

### Clients

`magnum-web`: confidential Phoenix BFF client, code/standard flow only, S256 PKCE
required, exact callback/logout allowlists, no implicit/direct/password/device/
CIBA/service-account grant, no browser token CORS, no offline-access optional
scope. Realm import uses Keycloak's supported `${MAGNUM_WEB_CLIENT_SECRET}`
environment substitution. React receives no client secret or bearer credentials.
Future Phoenix `OIDC_CLIENT_SECRET` must equal that local value. Secrets are not
read into Phoenix in this milestone.

`magnum-api`: bearer-only resource/audience definition, no interactive login.
An explicit mapper adds `magnum-api` to web **access-token** audiences, not ID
tokens. Audience is not permission. Future API verification must validate
signature, allowed algorithm, issuer, audience and expiry, then load local
account/membership authorization. Map identity by immutable `(issuer, subject)`,
never mutable email. Appointment customers remain separate from users.

Future `magnum-ios` / `magnum-android` will be separate public code+S256 clients,
system browser, exact app/universal-link redirects, secure device storage and
revocable credentials, with no embedded secrets. They use the same realm user
identity/API audience. They are documented, not enabled/provisioned yet.

The realm contains no real users, business roles, shop groups or memberships.
Keycloak may create its standard built-in administrative/account clients/roles;
these are identity-server internals, not Magnum authorization.

## Password, MFA and step-up baseline

Active now: minimum 15 / maximum 128 characters, long passphrases, not-equal-to
username/email checks, email verification enabled, self-registration disabled,
password reset available, temporary brute-force delays after five failures.
There are no composition requirements, forced periodic expiration or password
history requirement. Keep Keycloak's default supported password hashing.
The username/email checks reject equality, not every derived/similar password.

Common-password blacklist enforcement is **deferred**, not silently claimed.
Keycloak supports `passwordBlacklist(filename)` with a UTF-8, one-password-per-line
file under `/opt/keycloak/data/password-blacklists/` (or the provider's configured
directory). Select a maintained, licensed list and its update/provenance policy,
mount it read-only, add that policy to realm JSON and validate clean bootstrap.
The image is not assumed to include a suitable list. No arbitrary list/custom
provider is vendored. Dynamic scoring/live breach checks remain future work.

Configured but not enforced: standard TOTP settings; WebAuthn/passwordless RP ID
`auth.magnum.test`, user verification required, resident keys for passwordless
credentials. Default Keycloak authentication flows remain unchanged. This does
**not** prove MFA enforcement or allow usable HTTP passkey enrollment. No users
are provisioned, no custom brittle flow is added, and no God Mode ACR is claimed.

The BFF/flow milestone must enforce staff MFA, test phishing-resistant passkeys,
recovery, enrollment and fresh step-up proof (`acr`/`auth_time`). Phoenix will own
God Mode eligibility, reason, target tenant, short expiry and audits; Keycloak
proves stronger authentication only. Business admins cannot grant platform access.

Realm token lifetime is five minutes; SSO idle/max are 30 minutes/eight hours.
These are IdP settings, not implemented Phoenix cookie/session policy. Future
BFF sessions require Secure/HttpOnly cookies, CSRF protection, state/nonce/PKCE,
fixation protection, encrypted server-side refresh credentials and revocation.

## Health, SMTP and smoke tests

Health **and metrics** are enabled, so readiness includes database connection
health. Management port 9000 offers `/health/started` (initialization),
`/health/live` (process liveness), `/health/ready` (traffic readiness). The official
Bash TCP healthcheck probes readiness; it does not install curl or restart a
healthy process just because its DB is temporarily unavailable. Compose waits
for healthy PostgreSQL/Mailpit and Keycloak readiness before smoke requests.

Keycloak SMTP uses `auth-mail:1025`, no credentials/TLS, through the development
network. Inspect mail at `http://localhost:8025`. The host-facing bridge permits
outbound traffic; it is not an SMTP egress firewall. No SMTP host port, relay or
real mail provider is configured. Smoke checks confirm the configured sink,
its SMTP greeting from Keycloak's network and Mailpit's API; they create no users
or emails.

```sh
python3 scripts/auth.py smoke
curl --fail http://auth.magnum.test:8080/realms/magnum/.well-known/openid-configuration
curl --fail http://auth.magnum.test:8080/realms/magnum/protocol/openid-connect/certs
```

Smoke checks start/wait for the services; check all three health probes, an UP
database readiness check, own DB identity, exact discovery endpoints/issuer,
usable RS256 public signing-key metadata, live Admin API client/flow/PKCE/redirect/
audience settings and SMTP. The local bootstrap account reads selected non-secret
responses in memory using an ephemeral CLI config that is removed on exit.
Nested JSON is inspected without the CLI's lossy `--fields` projection; the
runtime client secret is compared with its environment value without printing or
persisting it. Credentials/tokens are never printed; no fake identities are
created. Run `reset` above to additionally
prove clean reset/rebootstrap. Live checks require Docker, host DNS and the ignored
env file; `check` and the Python unit checks run without Docker.

The source guard rejects obvious literal secrets, tokens, users and application
roles. It is a useful guard, not a comprehensive secret scanner. Review diffs;
never commit environment files, tokens, raw exports, captured mail or auth state.

Existing regression suites run with the auth profile stopped:

```sh
cd backend
mix format
mix test
mix compile --warnings-as-errors
mix precommit
```

From `frontend/`: `npm run lint`, `npm run build`, `npm run test:e2e`. Existing
anonymous E2E remains isolated in `scheduler_api_test_e2e`; no auth flows replace it.

## Production differences and next milestone

Do not deploy this start-dev/HTTP/bootstrap/SMTP-sink stack to production.
Production needs pinned/optimized images, HTTPS canonical issuer, trusted proxy
headers, private management/admin access, secret management/rotation, dedicated
least-privilege DB credentials, backups/restoration, monitoring and real SMTP.
Use one application realm per environment, isolated infrastructure/credentials;
do not create realms per business/shop. Never promote the local volume or secrets.
Keycloak administration and Magnum God Mode remain separate privileges.

Next milestone: identity-only Phoenix BFF OIDC integration with local immutable
identity mappings and revocable server-side web sessions, verified callback,
refresh/logout/CSRF and focused real-Keycloak integration tests. Decide the OIDC
library, same-origin frontend/proxy arrangement, HTTPS plan, MFA/recovery flow and
session/revocation policy first. Logging in must not grant admin access; protect
the admin endpoint only once explicit Phoenix membership/shop authorization is
implemented. No authentication handler is included here.

## Live verification record — 2026-10-27 (America/Denver)

Verified on macOS arm64, Docker Engine/CLI 29.9.2, Compose v5.6.1, context
`desktop-linux`, local Unix socket, running Docker Desktop engine `aarch64`.
No Docker target overrides, host settings, certificates or hosts-file changes
were made. `auth.magnum.test` already resolved to 127.0.0.1; ports 8080, 9000 and
8025 were free before startup. No emulation or platform override was required.

Resolved native ARM64 manifest digests (version tags remain unchanged):

| Image | linux/arm64 manifest digest |
| --- | --- |
| Keycloak 26.8.1 | `sha256:f259c5f8fcfd6e7a55d9a2dc020c63ac8fc788e63bf9d9cbab9f1244d119e5f9` |
| PostgreSQL 18.6 | `sha256:a8be76d23699a6c366437e9f80ead007975f24c35e01c9ee0533c6930ab57ac1` |
| Mailpit v1.32.0 | `sha256:846fbb9d54be56bc6c1ad0f592239452448fac958545578743a9683277f0082f` |

First boot imported `magnum`. All startup/liveness/readiness probes returned UP.
Stopping only auth PostgreSQL produced readiness DOWN/503 while liveness stayed
UP/200; restoring PostgreSQL restored readiness. Discovery issuer and all checked
endpoint URLs matched the canonical contract; JWKS contained usable RS256 keys.
Live realm settings matched source, including password/TOTP/WebAuthn policies.
The runtime client secret matched environment injection without being printed.
Client flow/PKCE/redirect settings and audience mapper passed structural checks.
Token-level audience assertions remain deferred until real BFF authentication.

SMTP configuration matched the sink, its greeting was reachable from Keycloak,
and Mailpit's host API responded. No Magnum users or test email were created.
The browser flow retained conditional 2FA: mandatory staff MFA and fresh God Mode
step-up are not enforced yet. HTTP passkeys remain unsuitable for realistic use.

Normal stop/start preserved realm ID and signing keys. Reset removed/recreated
only these positively labeled project resources:

- Containers: `magnum-auth-dev-keycloak-1`, `magnum-auth-dev-auth-db-1`,
  `magnum-auth-dev-auth-mail-1`.
- Volumes: `magnum-auth-dev_auth-postgres`, `magnum-auth-dev_auth-mail`.
- Networks: `magnum-auth-dev_auth`, `magnum-auth-dev_auth-local`.

The ownership guard checked project/config-path labels, known resource identities,
and foreign consumers. Unrelated Docker inventory IDs were preserved. Reset
created a new realm ID/signing keys and passed the full smoke suite. Scheduler's
separate development database retained identical full-row hashes and counts:
1 business, 1 shop, 3 services, 3 vehicle sizes, 9 prices and 1 appointment.
The pre-existing HomePage edit and ignored secrets file retained their hashes.

Corrections proven necessary by live verification: a host-facing bridge for
published Docker Desktop ports; removal of lossy nested-map CLI projections;
positive resource-ownership checks before destructive reset. Regression guards
cover these boundaries. No application API, routing or scheduling code changed.

Verification passed: 13 Python tests, source/config checks, live smoke after
bootstrap/restart/reset; backend format, 112 tests, warnings-as-errors compile,
precommit and format check; frontend lint/build and 14 anonymous Playwright tests
with auth stopped. Playwright required an unsandboxed rerun because the sandbox
initially denied its Phoenix server's local TCP lock. No tests were weakened.

## Official references

- [Keycloak 26.8.1 release](https://www.keycloak.org/2026/10/keycloak-2681-released)
- [Containers](https://www.keycloak.org/server/containers), [database support](https://www.keycloak.org/server/db)
- [Import semantics/environment substitution](https://www.keycloak.org/server/importExport)
- [Canonical hostname](https://www.keycloak.org/server/hostname), [health and metrics](https://www.keycloak.org/observability/health)
- [Versioned password policies](https://github.com/keycloak/keycloak/blob/26.8.1/docs/documentation/server_admin/topics/authentication/password-policies.adoc)
- [PostgreSQL 18.6](https://www.postgresql.org/docs/release/18.6/)
- [Mailpit v1.32.0](https://github.com/axllent/mailpit/releases/tag/v1.32.0), [runtime configuration](https://mailpit.axllent.org/docs/configuration/runtime-options/)
