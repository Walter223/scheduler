# Admin Command Center foundation (5A)

`GET /api/admin/context` requires the existing live browser session, returns
no-store JSON, and accepts no selectors or query parameters. Response:
`{businesses:[{id,name,capabilities,all_shops,shops:[{id,name,capabilities}]}]}`.
No user memberships, role labels, employee profiles, compensation or provider
metadata are returned. Each capability derives from one current complete grant
in Authorization, with account, membership, business and shop eligibility checked.
The policy is unchanged. Employees without management grants have no workspaces.

Area keys: dashboard, appointments, employees, schedules, compensation, access,
settings. `all_shops` names only operational areas supported by a business-wide
grant. Shop-only grants never receive All Shops merely by covering today's shops.
Manager access means restricted staff delegation, not Owner membership controls.
Compensation means eligibility for domain-protected reads, never Owner-pay access.
Selectors and navigation are presentation hints, never capabilities accepted by APIs.
Every future feature request must use its existing protected scoped endpoint.

The direct `/admin` frontend keeps Phoenix login/callback and opaque session/logout
unchanged. The public navbar is absent inside the shell; public pages retain their
existing navigation and booking. Desktop sidebar and mobile Menu expose only
server-provided areas. All feature areas are placeholders, not management screens.
Business changes reset shop and active area. Logout clears local context. Window
focus and explicit Refresh access reload current permissions, clearing stale data
before fetching. No idle-renewing polling is introduced. 401/403 and network errors
remove private workspace content. Already-rendered navigation is not an instantaneous
revocation notification; all protected APIs remain immediately authoritative.

Verification: backend HTTP tests use real isolated sessions/grants and SQL; component
tests simulate discovery responses for UI transitions only. Anonymous Playwright adds
an AdminPage POM/mobile keyboard-entry check while retaining all booking/API tests.
Authenticated multi-role/mobile browser acceptance is now covered by the isolated
real-Keycloak suite below. Production MFA/deployment hardening remains separate.

## 5A-B authenticated acceptance infrastructure

`npm run test:auth` now prepares seven active test identities plus the existing
unknown/pending identity. Explicit isolated grants cover Owner alone, Manager,
two-shop Shop Manager, Employee (deliberately Owner-classified employment without
management grants), Owner-A/Manager-B and Owner of both businesses. No real users
or operational data are used. The real-login suite contains nine tests total:
existing session/CSRF/logout and pending denial, four role-navigation cases,
mixed-business switching plus live membership revocation, two-business Owner/mobile
keyboard navigation, and deterministic session expiry on the next context request.
The Manager case also verifies an Owner-only membership write receives HTTP 403.

Fixtures use run-owned tenant slugs and exact issuer/subject user mappings in
`scheduler_api_test_auth_e2e`; cleanup removes owned employment classification,
RBAC and tenant records before account/session cleanup. The seed is atomic. A
separate `check_seed` command validates fixture capability counts without claiming
real Keycloak authentication. Controlled revoke/expiry commands are local Mix
fixture operations guarded by test environment, dedicated database and run ID;
no test-control HTTP endpoints exist. All ordinary logout sessions must be revoked;
the one deliberately expired Shop Manager session is checked separately.

Port guards run **before** Docker/Keycloak/database operations. The test runner
uses Phoenix **127.0.0.1:4002** and Vite **localhost:5174**, with exact callback
`http://localhost:5174/auth/callback` and web origin `http://localhost:5174`.
It creates a random per-run confidential Keycloak client (named with the owned
run UUID), with fresh memory-only secret, Standard Flow, S256 PKCE, RS256, no
implicit/password/service-account grants, and no wildcard redirects. The original
`magnum-web` client, realm settings and development accounts are unchanged.

The alternate provider/browser configuration exists only in `scripts/auth_e2e.exs`,
after guards require MIX_ENV=test, database scheduler_api_test_auth_e2e, a valid
owned run UUID and matching client ID. Normal Config/BrowserConfig constructors
are unchanged. Real OIDCC validation still checks the exact configured issuer,
per-run audience, signature, azp, nonce, PKCE and strict expiration. State/binding,
server-side sessions, cookie flags and exact Origin/CSRF checks are unchanged.
Only local HTTP Secure=false is used in this isolated browser context.

Reproduce from `frontend/` with Docker Desktop running, the documented local
issuer hostname resolving, PostgreSQL available and **4002/5174 free**:

```sh
PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH" npm run test:auth
```

Run separately from anonymous `npm run test:e2e`, which shares those test ports.
Neither suite reuses/stops developer servers on 4000/5173. The auth runner removes
its own client/users, SQL fixtures and managed servers in finally cleanup; it does
not reset Keycloak, remove volumes or stop shared auth infrastructure. Browser
traces/screenshots/video remain disabled to avoid retaining credentials.

Completion evidence: **9/9 real-Keycloak browser tests passed, zero retries**,
including role matrix, mixed scopes, Owner-only inheritance, revocation, mobile
keyboard operation, expiry, CSRF/local logout and pending denial. The preceding
synthetic fixture lifecycle check was not counted as real authentication evidence.
No full management screens, exhaustive accessibility audit, MFA/passkey hardening
or production readiness claim is included in this milestone.

5B replaces the operational Dashboard placeholder with authorized daily totals and
appointments. See [DASHBOARD_API.md](DASHBOARD_API.md) for scope, per-shop date/DST,
counting semantics and privacy. HR-only workspaces retain their permitted navigation
without operational scheduling data. Other areas remain placeholders.

5C-1 implements the read-only [Employees/HR directory](HR_DIRECTORY_UI.md).
Business `employees` capabilities enable HR profiles/history; shop `roster`
capabilities enable only the approved current-shop contacts. Classification grants
nothing. Other unfinished management areas remain placeholders.

5C-2A adds business `hr_manage` (existing `employment_manage`) and `hr_shops`
(active same-business id/name choices for authorized HR managers). These are separate
from operational shops and do not grant scheduling authority. See
[HR_MANAGEMENT_UI.md](HR_MANAGEMENT_UI.md) for the forms and CSRF/write boundaries.
