# Customer signup — 6A-2B

The Magnum platform landing at `/platform` links to `/signup`; the detailing Home no longer advertises business registration. Signup never replaces
employee `/admin` login. Verification POSTs JSON to `/auth/signup/login`; its
opt-in JSON response carries the authorization URL for a normal browser navigation
(fetch must not follow a cross-origin Keycloak redirect). Native non-JSON callers
retain the original redirect. Valid signup callbacks return to `/signup`, and
validated signup cancellations/errors return a safe signup error there.

The page loads only the masked CSRF token from GET `/auth/signup`; proof and browser
binding stay in HttpOnly cookies. No browser storage, provider tokens, operator
credentials or owner selectors are used. Review submits exactly business name/slug
and first-shop name/slug/timezone. The server remains authoritative. An uncertain
network result locks editing and allows identical retry. Confirmed success tells
the Owner to use ordinary login; signup does not issue a session.

Prerequisite: deploy both 6A-1 and 6A-2A migrations before updated application code.
Do not migrate development records merely for browser tests. The existing isolated
`npm run test:auth` runner migrates only its `_auth_e2e` database, uses exact temporary
Keycloak client callbacks and disposable identities, and owns ports 4002/5174.
Its cleanup includes signup-owned proof, intent, audit, grant and tenant rows.

Real signup acceptance extends the existing suite with pending and active identities,
slug conflict/recovery, new-Owner login/context isolation, cookie attributes, no
browser storage, responsive layouts and screenshots in `/private/tmp/magnum-signup/`.
The pending browser case expires its proof cookie and verifies again through real
SSO; both cases check duplicate clicks issue one request. Exact server-side expiry
and network/retry/error behavior also have component/backend coverage. Live provider
outage and cancellation were not deliberately induced; this does not claim exhaustive
provider-failure browser coverage.

Screenshots: entry.png, validation.png, pending-form-{1440,1024,768,390,320}.png,
owner-form-{1440,1024,768,390,320}.png, pending-success.png, owner-success.png.
No password-entry screen, provider token or proof cookie is captured.

See [platform routes](PLATFORM_ROUTES.md) for the dedicated Setup/operations navigation and unchanged OIDC return boundary.

## P0 signup recovery and acceptance

Signup now supports an explicit Create Account action via Keycloak's documented
OIDC `prompt=create` extension. It uses the same signup-purpose transaction,
nonce/state/browser binding, code flow and PKCE. Normal login never adds that hint.
Passwords stay entirely in Keycloak. The existing development `magnum` realm has
registrationAllowed=false: it must be explicitly reviewed/enabled by its operator
before new-user registration is available there. No runtime realm setting is
silently reconciled or changed by this repair.

Completed proofs can return a minimal confirmed business name/ID and first-shop ID
from GET /auth/signup, allowing refresh to restore success without a new tenant or
session. Their original ten-minute expiry, browser binding and live account checks
remain enforced. This is a creation receipt, not current authorization. Success
remains until the user deliberately follows the normal sign-in link. A refresh
after proof expiry requires verification again; it never automatically creates a
second business. Do not present a frontend-only success marker as provisioning proof.

Timezone suggestions come from read-only GET /auth/signup/timezones using the same
PostgreSQL timezone catalog as provisioning validation. The native searchable
combobox exposes exact identifiers and region/city labels, including aliases.
Browser timezone is only an editable initial suggestion. Phoenix validates writes.

Booking website address and first-shop identifiers derive from names until edited.
They reserve identifiers, not published sites. FieldHelp is a reusable native
summary/details disclosure: click/tap/Enter/Space toggle, Escape or Close help closes
and returns focus. Explanations wrap inline instead of using a clipped overlay.
For later Staff/Services/Pricing/Branding adoption, pair a separate label/input ID
with FieldHelp, use short task-specific explanations, and test keyboard, touch,
focus return and narrow widths. Do not add help buttons inside input labels or
change domain permissions/validation when adopting this pattern.

Real acceptance now starts Owner signup from an existing Magnum session via
/platform, checks named success/refresh, missing proofs, missing CSRF, invalid
timezone, changed replays, simultaneous identical retries, account ineligibility,
slug conflict and a browser-injected 503. Backend independent-connection tests cover
first-consumption races. The complete runner checks resulting proof, tenant, shop,
membership, business-wide grant and audit relationships, not UI alone.

The runner creates an owned temporary Keycloak realm with registration enabled;
the development realm and its identities are untouched. Fresh browser registration
proves email verification blocks completion. A guarded fixture command reads only that disposable recipient from local Mailpit;
the browser follows the real email action and sets its password only in Keycloak.
No administrative email-verification override or password reset is used. Owned
verification messages are cleaned individually; unrelated mail is preserved.
Temporary realm/users/client, database fixtures and owned processes are cleaned.
This test-realm isolation does not imply one Keycloak realm per customer business.

Run full acceptance: npm run test:auth. Focused runs: npm run test:auth -- --spec
zz-signup.spec.ts --spec zzzzz-registration.spec.ts. Focused runs preserve cleanup;
complete fixture-outcome assertions run on the full, unfiltered suite. Free ports
4002/5174 are required; user-owned 4000/5173 are never reused or stopped.
Screenshots remain in /private/tmp/magnum-signup and successful runs copy them to
the permanent 6a-2b-signup archive, including registration entry and mobile help.

Development diagnosis found one unconsumed signup proof, no signup provisioning
audit/result and only the original business. Authenticated-Owner reproduction of
the prior code passed. The original reported /admin navigation is not attributed
to provisioning or session interference without its actual request/navigation log.

Final evidence and scenario matrix: [signup regression checkpoint](../docs/signup-regression.md).
Keycloak registration uses its [supported prompt=create flow](https://www.keycloak.org/docs/latest/server_admin/).

### Missing or expired signup verification

GET /auth/signup returns 403 with JSON `{"error":"signup_unavailable"}` when
the browser has no valid onboarding proof/binding pair. An ordinary authenticated
session or temporary `magnum_login_dev` OIDC binding is not that proof. Status
reads do not consume it; successful business provisioning does.

Open http://localhost:5173/signup and choose Continue to verification to explicitly
restart signup, complete Keycloak, and return to the business form. Keep localhost
consistent; host-only cookies do not transfer to 127.0.0.1. Avoid starting competing
OIDC attempts in other tabs: the newest attempt replaces the temporary binding.
Ordinary /auth/login intentionally returns to Admin and cannot restart signup.

The page explains this rejection without automatically redirecting or starting
OIDC. React StrictMode can abort its first status fetch, leaving an unreadable
response body in browser tools; inspect the completed request. Never share cookie
values or callback query strings. Focused real-provider recovery coverage:
`npm run test:auth -- --spec zzzzzz-signup-recovery.spec.ts`.
