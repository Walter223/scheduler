# Magnum platform/customer separation — 7A-3B

| Route | Experience |
|---|---|
| `/platform` | Magnum SaaS landing, Create a Business and Sign In |
| `/signup` | Existing secure signup/provisioning UI with platform navigation |
| `/admin` | Existing authenticated operations workspace |
| `/setup/:businessId` | Dedicated Owner-only business Setup layout |
| `/`, `/services`, `/contact` | Existing Magnum Detailing customer site/booking |
| `/auth/*` | Existing Phoenix authentication and signup protocol routes |

No tenant is special-cased in new routing logic. Existing customer routes remain
legacy compatibility entry points, not generic platform marketing. The earlier
Create a business link is removed from the detailing Home. Platform links identify
that Home as an individual customer's website, not the SaaS company homepage.

Signup proof transport, provisioning, normal login, Keycloak callback and the
strict `/admin` login return-path allowlist are unchanged. After confirmed signup,
ordinary login opens Admin, where an authorized Owner chooses Resume Setup. No
arbitrary `return_to` URL or persisted secret/redirect intent is added.

Admin retains a Resume Setup link outside daily-operations navigation. Its fixed
local URL carries only a business selector. Setup reuses the existing Admin session/
context orchestration in a dedicated layout and mounts the single SetupWorkspace
component. It does not create a second draft or load dashboard/HR/calendar modules.
Only businesses with current server-derived `setup` capability appear in its
business selector. An unrecognized/unauthorized Setup ID does not fall back to a
different business and never triggers a draft request. APIs remain authoritative.

Setup's Open management workspace link uses `/admin?business=ID`; the ID is matched
against fresh authorized context. It is not an authorization claim or external
redirect. Explicit Admin business selections also replace this selector in the local
URL, so returning with browser history preserves the intended business. Business switching in Setup changes the route, clears private component
state and reloads the corresponding persisted draft. Refresh/deep links reload
sessions/context; back/forward restoration additionally revalidates on persisted
pageshow. Signed-out deep links offer normal login and reveal no draft. Logout,
revocation and context failure retain existing protected-data clearing behavior.

Platform, signup and Setup use professional, scoped dark styling. The public
shop's logo, neon styling, services and booking remain intact. Draft proposals and
unpublished status stay explicit; operations access is not publication readiness.
There is no automatic Complete/Publish action or automatic redirect based on an
AI-defined readiness claim.

Future tenant public booking should use a generic persisted resolver, e.g.
`/book/:business_slug/:shop_slug`, with explicit active/published gates and safe
catalog/availability ownership. Existing public paths can remain configured aliases
for their current business. Do not add name-specific routing or assume business
creation enables public booking. Canonical platform domain/hostname, eventual
root-route migration and custom-domain/TLS policies remain deployment decisions;
no production hostname or new OIDC callbacks are invented here.

Verification uses existing isolated auth fixtures and cleanup. Screenshots live in
`/private/tmp/magnum-platform/`: platform/signup/setup at 1440,1024,768,390,320;
detailing-home at 1440/390; Admin resume at 1440/390 and management return at 1440.

Signup recovery keeps successful creation on /signup, including refresh while the
browser-bound proof remains valid. The user explicitly starts ordinary login only
after seeing the confirmed company name. Neither the existing Admin session nor
frontend business selection determines a signup owner or changes OIDC purpose.
See SIGNUP.md for isolated registration acceptance and the development realm's
explicit registration-policy prerequisite.
