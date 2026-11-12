# Signup repair and real-account acceptance checkpoint

## Confirmed development evidence

Read-only inspection found only Magnum Detailing (business 1), its existing three
shops, one active membership and one active Owner grant. The active verified local
Owner had one unconsumed signup proof, no signup audit or completed provisioning
receipt, and no new business. The loopback signup IP budget contained only the
initiation attempt; no creation budget was committed. A later ordinary-login
transaction existed. This locates the unresolved failure before successful
provisioning, but does not establish whether creation was never dispatched or
rejected before its attempt counter. The original HTTP status/navigation initiator
was unavailable. Authenticated-Owner reproduction of the previous code passed.
Do not claim that the original personal-account redirect has been diagnosed/fixed.

Confirmed recovery defects repaired: completed proof status rejected refresh,
success omitted the business name, registration had no explicit entry, and timezone
entry had no supported-value suggestions. Success now restores backend-confirmed
name/IDs within the unchanged proof lifetime. No automatic Admin navigation occurs.

Live magnum registrationAllowed=false, verifyEmail=true, confidential magnum-web,
exact callback http://localhost:5173/auth/callback, S256 required, implicit/password
grants disabled. No live policy/user changes were made. New-user registration there
requires an explicit operator decision; existing verified identities do not need
registration enabled. Discovery, public services and proxy checks passed. A transient
timezone 503 cleared on read-only recheck; latest endpoint returned 200 without restart.
Schema preflight was current; this repair has no migration. No personal session was used.

## Final verification

| Check | Result |
|---|---|
| Focused signup/provisioning/controller/concurrency | 48 passed |
| mix precommit | 579 passed |
| Component tests | 130 passed |
| Frontend lint/build, Python syntax, diff checks | Passed |
| Full real-Keycloak acceptance | 38 passed; complete DB verification and cleanup passed |
| Additional focused browser history verification | 2 passed; success survives back/forward without another creation |
| Anonymous Playwright browser/API | 24 passed, two workers |

An existing global SQL telemetry assertion in UpcomingAppointmentsTest intermittently
captured unrelated queries in earlier precommit runs. It was not changed or weakened;
the final run passed. Successful unchanged checks need not be repeated without cause.

## Scenario coverage

| Scenario | Evidence/result |
|---|---|
| Verified pending identity creates first business | Real browser/BFF/provider + committed audit/receipt verification: pass |
| Already-signed-in Owner creates another business | Real /platform entry with existing session, real signup callback and creation: pass |
| Fresh account registration | Real provider registration, actual local SMTP/Mailpit verification link, Keycloak-only password setup and first business: pass |
| Correct tenant/shop/membership/Owner scope | Full runner checks proof IDs, shop ownership, membership target, NULL shop Owner grant, audit actor and activation outcome: pass |
| Named success, refresh and deliberate ordinary login | Browser confirmation stays on /signup, restores after refresh/back/forward and exposes no create button; normal login/new company selector: pass |
| Missing/cross-browser proof and expired proof | Isolated cookie jar HTTP denial; browser cookie expiry/reverification; exact server expiry tests: pass |
| Unverified or ineligible identity | Provider blocks unverified registration before proof; suspended real fixture proof/status and stale session denial; backend covers deactivated/unverified cases: pass |
| Normal login vs signup purpose | Real authenticated signup remains separate; deterministic HTTP checks ordinary/registration purposes and clean canceled-signup callback: pass |
| CSRF/origin | Actual HTTP missing/invalid CSRF and foreign Origin denials: pass |
| Duplicate slug, invalid timezone and payload injection | Browser recovery/actual HTTP rejection and strict backend validation: pass |
| Duplicate click/retry/concurrency | One UI submission, simultaneous committed-proof HTTP retries return identical IDs; changed replay conflicts; independent DB first-consumption races: pass |
| Simulated failures | Browser-injected signup-start and creation 503 recovery; component network uncertainty/idempotent retry: pass. Shared provider was not stopped |
| Cancellation | Purpose-bound error callback HTTP test passes; real Keycloak cancellation UI was not executed |
| Cross-tenant access, revocation, expired sessions | Real browser/API denies unrelated tenant; existing Admin suite covers revocation and expiry: pass |
| Help and timezone UX | Name-derived/custom identifier behavior; native searchable supported-zone list; click/keyboard disclosure, Escape/focus return and 320px captures: pass |

The browser scenarios use a unique owned Keycloak realm and isolated _auth_e2e DB.
The registration email helper reads/deletes only the exact run-owned recipient;
it never administratively verifies an email or sets a password. Test credentials,
email action URLs and client secrets remain private temporary fixtures. Full cleanup
removes owned realm/users/client, messages, tenant/account/session/proof fixtures
and test-owned processes. Source development realm and data remain intact.

## Captures and manual follow-up

Final permanent captures: /Users/TravisBigelow/projects/Magnum-Screenshots/6a-2b-signup/
The final run is `2026-11-11T23-06-55.743Z-7218e92d`. It includes registration entry (1440/390), entry/validation,
forms at five widths, success (1440/390), and help at 320. Originals remain in
/private/tmp/magnum-signup. FieldHelp and usage are documented in frontend/SIGNUP.md.

To isolate the original redirect, collect only method, path, response status and
Initiator for /auth/signup/business and any subsequent /auth/login request. Do not
share callback query strings, cookies, tokens, headers or credentials. Distinguish
Review business from the final Create business action. Creating a company in the
actual development database still needs separate explicit authorization. No actual
Owner login or real company creation was performed by the agent.
