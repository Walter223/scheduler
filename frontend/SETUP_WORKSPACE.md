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

Business, Locations, Staff, Services, Branding and Review are navigation views,
not invented completion percentages. The saved backend workflow/revision is shown.
Locations may advance only through the backend validation endpoint. Staff, Services
and Branding editing remain planned; existing proposal values are preserved.
Review shows proposal counts, location/mobile details and missing fields, with
unpublished/unapplied warnings. It never enables invitations, mobile booking,
catalog publishing, AI operations or public booking. There is no Complete/Publish
control because the remaining configuration editors/application workflows are absent.

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
management and scoped role requests separately. Services/Branding remain planned.

Save/retry/conflict/reload and protected-data clearing reuse the existing workflow.
The Staff continuation uses the existing employees→services_pricing transition;
zero employees is valid. Server validation remains authoritative. No passwords,
provider data or private HR/pay fields are accepted. Legacy proposals require
explicit completion of missing required fields before saving the v2 entry contract.

Screenshots: `/private/tmp/magnum-staff-onboarding/staff-{1440,1024,768,390,320}.png`,
`validation.png`, `review-320.png`. Real-Keycloak acceptance uses owned disposable
businesses/identities and confirms save/resume/focus and duplicate-email denial.
No database migration is required; read-only development preflight reports current.
