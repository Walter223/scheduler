# SaaS onboarding and white-label readiness

Architecture audit, 2026-10-31. This is a proposed roadmap, not implemented signup or white-label functionality. Keycloak authenticates; Phoenix authorizes Magnum access. Authentication alone grants no tenant access.

6A-1 adds the internal [new-business provisioning foundation](../backend/BUSINESS_PROVISIONING.md)
for explicitly operator-authorized eligible identities. Public signup, pending-account
activation and publishing remain unimplemented; the proposals below still require those boundaries.

## Current support and gaps

| Area | Present in the repository | Still needed |
|---|---|---|
| Tenant persistence | Businesses with globally unique slugs; shops with business-scoped slugs, timezone and active/archived status. Composite foreign keys protect catalog, price and appointment ownership. | Authorized business/shop creation, settings and onboarding lifecycle. |
| Authorization | Independent memberships and fixed scoped grants; Owner inherits Manager capabilities; transactional role management, last-Owner protection and atomic audits. | Public signup, invitations, acceptance and explicit account activation. |
| Administration | Session-protected context discovery, business/shop switching, capability-based navigation and scoped operational/HR APIs. | Tenant configuration screens and onboarding. Existing selectors are hints, never authority. |
| Identity | Immutable issuer/subject mapping, pending accounts, verified-email eligibility, revocable sessions, one-time OIDC transactions and CSRF. No provider-token persistence. | A narrowly defined onboarding boundary for verified pending identities. |
| Public booking | Anonymous booking, business-owned catalog, shop prices, appointment snapshots and shop-scoped locks/exclusion protection. | Public tenant/shop resolution, publishing controls and configurable booking policies. |
| Branding/billing | Static Magnum presentation; no tenant branding, subscription or billing model. | Validated settings/assets and an independent subscription lifecycle. |

Current evidence: [Organizations](../backend/lib/scheduler_api/organizations.ex),
[tenant migration](../backend/priv/repo/migrations/20261027023327_establish_magnum_tenant_ownership.exs),
[Admin context](../backend/ADMIN_CONTEXT.md), [role management](../backend/ROLE_MANAGEMENT_API.md),
[authentication](../backend/AUTHENTICATION.md).

## Hardcoded assumptions

- `Organizations.default_business!/0` selects `magnum-detailing`; `default_shop!/0` selects its `default` shop. These are literal slugs, not configurable tenant discovery.
- The historical migration created **Magnum Detailing Default Location**, with `America/Denver`, and backfilled existing operational rows. Do not rewrite that migration or move those rows for onboarding.
- Public services, availability and appointment controllers use default-shop context functions. Some catalog creation helpers also default to Magnum. Explicit shop-aware functions exist, but there is no public tenant route today.
- Availability uses Denver conversions, 09:00–18:00 opening hours, Sunday closure, 30-minute slot increments/buffer and a 90-day horizon. A shop timezone field alone does not make booking timezone-configurable. Availability and appointment validation must change together.
- Seeds populate the default shop with Basic/Mid/Supreme Detail, Small/Medium/Large sizes and fixed prices/durations. They are not a new-business provisioning service.
- The frontend has root `/`, `/services`, `/contact` booking routes, imported Magnum logos, Magnum text/alt text, static styles and an HTML title of `frontend`. It has no tenant branding bootstrap or tenant-prefixed navigation.

## Proposed signup boundary

Existing login synchronizes unknown identities as **pending** and issues no usable session. Existing operator Owner bootstrap requires an already active, verified user and an existing business with no Owner history; it is not a public signup service. Keep both safeguards intact.

For self-service, introduce an explicit **create-new-business** intent after verified OIDC authentication and verified email. A short-lived, single-use, browser-bound server-side onboarding proof may authorize only this operation; it must not be a normal Magnum session or permit access to existing tenants. Require CSRF/origin protection, bounded input and abuse limits. Keep the ordinary login return-path allowlist unchanged unless separately reviewed.

In one database transaction:

1. Lock/reload the identity and consume its onboarding proof; reject suspended/deactivated accounts and stale verification. Validate the idempotency key and approved creation intent.
2. Insert a **new** business and first shop with validated slug, IANA timezone and explicit safe defaults. Never accept an existing business ID, arbitrary owner ID, role or status from the caller.
3. Create that user's active membership and one business-wide Owner grant; persist a truthful self-service provisioning audit atomically. Reuse integrity constraints and shared locking conventions, without weakening normal Owner-authorized role management or operator bootstrap.
4. If approved as product policy, explicitly activate a pending account as part of this narrowly scoped new-tenant workflow. Login synchronization itself must never activate accounts. Already eligible active users can create another business through a new explicit intent.
5. Create a fresh eligible local session; issue its cookie only after commit. Failure, including audit failure, rolls everything back. Keycloak and email operations must not occur inside the database transaction.

Use unique database-backed idempotency keyed to the identity and intent/payload, plus atomic proof consumption. Concurrent retries must return the same owned result or a safe conflict, never another tenant's identifiers. Slug collision does not establish ownership. Names, email addresses, domains and matching customer records must never authorize claims on existing businesses. Existing ownership requires an authorized invitation/transfer; historical ownership recovery remains an operator-controlled separate process.

**Decision before implementation:** approve explicit new-tenant activation for verified pending identities and its limited onboarding proof, or retain operator activation for an initial pilot. Do not silently relax pending-session eligibility. Decide creation quotas/trial abuse controls while preserving legitimate multi-business ownership.

## Public routing, catalog and branding

Start with one application origin and explicit routes such as `/book/:business_slug/:shop_slug`. Resolve both to persisted active, published records, then pass the trusted shop through catalog, availability and appointment creation. Unknown/archived/unpublished tenants must not fall back to Magnum. Keep existing public routes as explicit Magnum compatibility aliases during migration.

Services and vehicle sizes remain business-owned; offered prices/durations remain shop-scoped. Reject foreign service-price IDs against the resolved shop. Appointment ownership comes from validated persisted relationships, never request ownership fields. Preserve historical snapshots, scheduling locks and exclusion constraints. Define per-shop timezone/hours policies before publishing shops in other timezones; test UTC crossover and DST in both availability and creation.

Customer contact currently lives on appointments; there is no separate customer-account provisioning workflow. Any future CRM customer identity must be business-scoped. Never turn booking emails into Accounts users, memberships or cross-business customer links.

Add business-owned branding settings with a small public projection: display name, approved logo derivative, constrained color tokens and approved public shop/contact details. Preserve Magnum's current appearance as its defaults. Branding writes require explicit current tenant permission; employment classification grants none. Validate colors against a strict format/token allowlist and maintain contrast/accessibility; do not accept arbitrary CSS, HTML or script.

Uploads need authorized tenant ownership, byte/pixel limits, file-signature validation, image decoding/re-encoding and generated storage keys. Initially allow reviewed raster formats, not arbitrary SVG/HTML or remote URL fetching. Quarantine originals, serve safe derivatives with correct content types from isolated asset storage, and reject references to another tenant's assets. No credentials in public metadata.

Custom domains should follow later: unique verified domain mappings, ownership verification, TLS, trusted-host routing and safe removal/reassignment. Keep BFF authentication on a canonical application origin with exact callbacks; do not introduce wildcard redirects, cross-domain session cookies or a Keycloak realm per business. White-label public booking does not automatically imply white-label identity-provider screens.

## Invitations, employment and switching

Invitations need expiring, revocable, single-use hashed credentials bound to the business, approved fixed role/shop and inviter. Verify the accepting OIDC identity/email and explicitly bind its issuer/subject; email delivery alone is not ownership proof. Recheck inviter authority and target/Owner protections transactionally at acceptance, audit grants and activation, and prevent replay. An existing identity must not gain permissions merely by signing in.

Employment linking is a separate authorized, audited operation against an explicit employment identity and period. Never match or link by email. Preserve nullable user links, rehire privacy and the rule that classification is not RBAC. Owner signup does not imply an employment record. Invitations must not automatically restore offboarded memberships, historical grants or previous-period access.

Reuse Admin context discovery for multi-business selection: one person can own two businesses or own one and manage another. Clear shop selections/private data on business changes, discard late responses and recheck live grants on every API request. All Shops requires a qualifying business-wide operational grant. Business branding, policies, integrations and future billing belong to the selected business/shop, not the global user.

## Subscription and tenant lifecycle

Introduce a business-owned subscription/provider-customer relationship separately from account eligibility, grants and business archival. Verify webhook signatures, enforce replay/idempotency protection and resolve provider IDs to persisted tenants. The server chooses plan/price identifiers. Billing events must not assign Owner roles or reactivate suspended users.

Decide trial limits, billing administrators, suspension/grace behavior and cancellation/export policy before enforcement. Preserve employment/pay/audit history and booked-customer obligations; payment failure must not cascade-delete tenants or historical records. Retention, tenant deletion and recovery need explicit policies. Production launch additionally requires MFA/deployment hardening and reliable email/abuse controls.

## Small implementation milestones and acceptance tests

| Order | Focus | Essential tests |
|---|---|---|
| 1 | Explicit authorized business/shop provisioning primitives and configuration validation; no public signup yet. | Atomic rollback/audit failure, slug races, tenant constraints, no changes to existing Magnum data, invalid timezones. |
| 2 | Reviewed pending-identity onboarding boundary and first-Owner creation. | Verified identity/email, blocked accounts, proof replay/browser binding/CSRF, duplicate concurrent signup, existing-tenant claim denial, exactly one Owner grant, multi-business independence. |
| 3 | Explicit public tenant routing and coordinated shop booking policies. | Foreign prices, unpublished/archived tenants, unchanged Magnum aliases, same service names across tenants, DST/day boundaries, shop-lock isolation and concurrent bookings. |
| 4 | Branding settings and validated asset pipeline. | Tenant write/read isolation, malicious/oversized files, asset ownership, safe colors, accessible fallback and tenant-aware navigation. |
| 5 | Invitations, explicit acceptance and employment linking. | Wrong identity, expiration/replay, revoked inviter, lower-role escalation, historical Owner protection, offboarding/rehire non-restoration. |
| 6 | Subscription lifecycle, then optional custom domains. | Signed/idempotent webhooks, cross-tenant provider IDs, grace/archival behavior, domain takeover prevention and exact auth-origin contracts. |

Open owner decisions: self-service activation/abuse policy; whether businesses start unpublished; editable booking policy defaults; branding scope versus custom domains; invitation identity/activation rules; subscription entitlements and retention. None is implemented by this document.
