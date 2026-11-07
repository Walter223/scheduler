# Customer signup — 6A-2B

Home has a separate Create a business link to `/signup`. Signup never replaces
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
