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
Authenticated multi-role/mobile browser acceptance remains pending an isolated RBAC
browser fixture. Real Keycloak test:auth is unchanged and requires free 4000/5173;
never stop user servers to run it. Production MFA and deployment hardening remain
required before privileged deployment. No migrations, grants to real users or
provider-token exposure are introduced.
