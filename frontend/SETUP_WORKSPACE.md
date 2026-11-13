# Owner Setup workspace — 7A-3

Setup appears only for the server-discovered `setup` capability, derived from the
existing Owner-only `access_manage` permission. Protected onboarding endpoints
remain authoritative. No domain authorization or persistence policy changed.

Owners explicitly begin a draft or load the existing revision. Business shows the
provisioned shops; Configure attaches each existing ID at most once. Added locations
are proposals, not inserted shops. Locations edits support defaults, per-shop
names/addresses/timezones/models, mobile coverage areas, dispatch references and
integer travel-buffer proposals. Shared mobile values inherit by field; arrays
replace. Empty override fields inherit where supported. No booking rules change.

Explicit Save uses session-bound CSRF and a durable request UUID. An uncertain
network result locks edits and retries the exact body. A revision conflict requires
explicit discard/reload; there is no silent overwrite or merge. Session/access
failure clears private drafts. Business changes unmount the keyed workspace and
abort requests; late responses are ignored. Normal focus-based revalidation keeps
the component mounted when authorized context remains valid. Nothing is stored
in browser storage. Leaving without Save loses only explicitly marked unsaved edits.

Business, Locations, Staff, Services, Branding and Review use the shared persisted
progress/navigation mapping. Viewing is separate from completion; only authorized
saved checkpoints count. See [UX-B1 progress contract](ONBOARDING_PROGRESS.md) for
percentages, the empty-team skip, readiness handling and Review confirmation.

Tests use disposable real-Keycloak role fixtures and the existing isolated runner,
including owned draft cleanup. Screenshots: `/private/tmp/magnum-setup/overview.png`,
`validation.png`, `review.png`, and `locations-{1440,1024,768,390,320}.png`.
Existing 7A-1 migration must be deployed before accessing Setup; 7A-3 adds no migration.

7A-3B moves this same component to the dedicated `/setup/:businessId` layout.
Admin retains an authorized Resume Setup link instead of a daily-operations Setup
section. See [platform routes](PLATFORM_ROUTES.md); draft/API semantics are unchanged.

## Staff stage — 7A-4

Staff now supports adding/editing/removing draft people with name, work email,
explicit classification, multi-shop assignments, intended management responsibility
and independently selected proposed access roles/scopes. No classification change
checks a role box. Every card clearly says proposed; no external notifications,
accounts, hiring or grants occur. Shop names resolve from stable keys. Removed or
unassigned references show an explicit clear/reassign warning rather than silently
removing intentions. Staff Review summarizes classification, assignments,
management and scoped role requests separately. Branding remains planned; Services is described below.

Save/retry/conflict/reload and protected-data clearing reuse the existing workflow.
The Staff continuation uses the existing employees→services_pricing transition;
zero employees is valid. Server validation remains authoritative. No passwords,
provider data or private HR/pay fields are accepted. Legacy proposals require
explicit completion of missing required fields before saving the v2 entry contract.

Screenshots: `/private/tmp/magnum-staff-onboarding/staff-{1440,1024,768,390,320}.png`,
`validation.png`, `review-320.png`. Real-Keycloak acceptance uses owned disposable
businesses/identities and confirms save/resume/focus and duplicate-email denial.
No database migration is required; read-only development preflight reports current.


## Services & Pricing stage — 7A-5A

Services supports custom vehicle categories, blank services and an explicitly
selected generic exterior-care suggestion. Owners enter their own names,
description, estimated minutes, intended offering status, delivery mode, offered
shops and shared category prices. Optional shop overrides customize duration,
status, delivery mode and individual prices without changing shared defaults.
Prices are entered as decimal USD and parsed into exact integer cents without
floating-point rounding. Missing/invalid values remain visible for correction;
Phoenix is authoritative. Removed category/shop references require explicit cleanup.

Save/reload/resume, conflict recovery, exact-request retries, session-bound CSRF,
context/focus preservation and authorization clearing reuse the existing workspace.
Review shows defaults, local overrides and unapplied/mobile warnings. Empty service
configuration is honestly deferred; only server validation permits advancing from
Services to Branding. Legacy proposals need explicit completion, not silent domain
application. No new API, migration or browser storage is introduced.

Real-Keycloak screenshots: `/private/tmp/magnum-catalog-onboarding/` contains
`services-1440.png`, `services-1024.png`, `services-768.png`, `services-390.png`,
`services-320.png`, `validation.png`, `review-1440.png` and `review-320.png`.
The isolated acceptance test saves custom categories/shared prices/mobile-shop
overrides, recovers from missing-price validation, reloads, revalidates focus and
reviews without applying catalog records. Existing role-denial tests remain active.

## Screenshot archive

Successful real-Keycloak runs copy intentional captures to `~/projects/Magnum-Screenshots/` with milestone/run folders and `latest/<area>` copies. Override with `MAGNUM_SCREENSHOT_ARCHIVE`; CI skips unless explicitly configured. Originals stay in `/private/tmp`. Sync existing captures with `node frontend/scripts/archive-screenshots.mjs` from the repository root. Archive failures never fail tests; failure artifacts/traces/videos and visual baselines are unchanged. Open the archive with `open ~/projects/Magnum-Screenshots`.

## Branding drafts — 7A-5B

Branding accepts display_name (255 bytes), optional tagline (200) and description
(2000), contact_email (254), contact_phone (7–15 digits, optional leading + and
spacing/parentheses/hyphens), primary_color/secondary_color/accent_color (six-digit
hex) and preset (modern/premium/minimal). Unknown fields and asset URLs fail.
Partial valid drafts can be saved; Review requires every field except optional
text. readiness.branding_configured is server-derived. Existing revisions, receipts,
Owner/session checks and metadata-only atomic audits apply. No migration is needed.

The scoped preview uses escaped React text, validated CSS colors and fictional
service cards with no booking links or availability. Mobile/desktop preview modes
are illustrative. Logo is a placeholder, never an arbitrary URL or upload. Future
uploads require authorized tenant-owned storage, bounded size/type validation,
decoding/re-encoding, malware checks, safe serving and audited asset references.
Custom palette contrast requires review before publication. No live website or
platform identity changes. Screenshots: /private/tmp/magnum-branding-onboarding/
with preset-{1440,1024,768,390,320}.png, validation.png, mobile-preview.png and
review-320.png; successful acceptance runs archive these automatically.

## Guided setup — 7B-1

No LLM or free-text transcript: deterministic topic prompts plus structured manual
editor input, server-validated proposals and explicit approve/discard operations.
GET/POST `/api/admin/businesses/:business_id/onboarding/guide` uses the same Owner,
session, CSRF/origin, no-store and bounded-parser boundary. POST requires exactly
action (propose/approve/discard), topic (locations/staff/services/branding), proposal
(topic-only patch for propose; null otherwise), revision and UUID request_id.
Unknown fields, unrelated patches and invalid domain data fail closed. Approval
reuses the existing draft mutation/validation and never applies live configuration.

Migration 20261110040000 adds private redacted guide_state JSON to the draft.
Entries are keyed by authenticated local Owner ID; other Owners cannot read them.
Business/member/session locks precede all guide operations. Every accepted command
advances the shared draft revision and atomically audits actor/revision; durable
receipt metadata records action/topic and prevents repeated writes. Concurrent manual
edits invalidate pending approvals and require reload/review. Historical receipts
are not rewritten. No automatic merge or forced override is provided.

History is bounded to 20 enum action/topic/revision entries, not chat text. Pending
structured proposals expire after seven days; expired entries are hidden immediately
and pruned on subsequent guide writes. Physical removal from inactive drafts and
backups requires an operator retention job/policy before production deployment.
Never enter credentials or personal identifiers in setup fields. Existing bounded
field allowlists apply; no arbitrary natural-language command is accepted.

Manual editors remain available. Guide proposals are separate from saved domain
proposals until explicit approval; approved data reloads the manual workspace.
Network uncertainty retries the exact UUID/body. Conflicts require reload. Normal
focus preserves mounted workspace; business/access changes clear private state.
Screenshots: /private/tmp/magnum-guided-onboarding/proposal-{1440,1024,768,390,320}.png;
successful real-provider runs copy them to the permanent 7b-1-guide archive.
Development migration requires explicit approval and has not been applied.

The Locations editor now uses the [UX-C1 First Location experience](FIRST_LOCATION.md):
plain-English service-mode cards, conditional mobile planning, an existing first-shop
reference, inline validation and explicit draft-only saves. It does not create a
second first shop or alter operational booking configuration.
