# Everyday employee HR management UI — 5C-2A

The existing Admin directory/profile gains Create Employee, Edit Contact, Change
Classification, Assign Shops and End Shop Assignment. These delegate exclusively
to the protected HR write endpoints in [HR_WRITE_API.md](HR_WRITE_API.md); no new
mutation route, persistence shortcut, lifecycle or authorization policy is added.
No termination, rehire, compensation, role, invitation or account-linking UI exists.

Current business `hr_manage` is derived from the existing `employment_manage`
permission on one complete business grant. Owner/authorized Manager gets controls;
Shop Managers retain read-only rosters; Employees get none. Historical/ended period
views remain read-only. An explicit selected history period never becomes an implicit
write target. Every mutation path contains stable employee and exact current-period
IDs, rechecked by the existing domain inside its transaction.

## Minimal discovery/projection additions

Admin context adds `hr_shops`, active same-business id/name choices only when the
actor has business-scoped HR management. This is separate from operational shop
capabilities: Managers gain neither scheduling data nor All Shops operational access.
HR shop-assignment projections add `assignment_id`, needed to target an existing
relationship for the existing end endpoint. IDs remain selectors, never authority.
Read-side tenant/shop constraints and private-field allowlists are unchanged.

## Forms and request safety

Native modal dialogs provide labels, browser input validation, focus confinement,
keyboard cancellation and mobile scrolling. Create needs names, classification and
an explicit start date, with optional supported business contacts; it needs no login
account. Contact payloads contain only first/last name, phone, email and home address.
Classification shows the current value and requires confirmation that this does NOT
change application roles. Shop management shows retained assignment dates/statuses;
ending a relationship explicitly leaves employment active.

Each submit obtains the current masked CSRF token from `/api/me` in an ephemeral
local variable and sends it in `x-csrf-token`. The browser supplies same-origin Origin
and the existing HttpOnly cookie. No session/provider credentials are read, stored or
exposed. A synchronous submission lock and disabled fieldset prevent duplicate
requests. Payloads are explicitly built; injected form fields do not become ownership,
linked-user, status, grant, pay or audit attributes. Server validation and authorization
remain authoritative; 401/403 clears private directory/profile state, and safe 422/409/
503 messages reveal no SQL, audit, provider or employee internals. Outstanding-work
conflicts direct the user to resolve shifts/jobs first. No security requirement is
relaxed to make a form succeed.

Writes are not optimistic. Success triggers authorized directory/profile reads.
Multi-shop selection uses separate existing single-shop requests, sequentially; it is
NOT an atomic batch. Partial success is reported and refreshed rather than rolled
back or falsely described as all-or-nothing. Ambiguous network outcomes ask the user
to refresh before retrying; no automatic POST retries or idempotency bypass is added.

Business/shop changes unmount the form and abort its requests; late results cannot
update another context. Aborting HTTP does not undo a mutation already committed on
the server. Dialog cancellation is disabled during submission; context teardown still
clears local private state. The domain's audit, locking, last-Owner/history, work
eligibility and lifecycle safeguards remain unchanged.

## Verification boundaries

Component tests cover explicit payload/CSRF handling, forbidden form-field injection,
classification IDs/no-grants, partial assignment success, bounded failures, duplicate
submits and unmount/late-response safety. Existing HTTP/domain regression covers role
and tenant denial, Owner history, malicious payloads, validation, work conflicts,
audit rollback and concurrency. Real-Keycloak browser cases exercise Owner and Manager
creation without linked users, contact/classification edits, two-shop assignment,
ending one relationship while employment remains active, mobile keyboard submission,
and authoritative re-reads. The guarded runner verifies new records are unlinked and
classification changes created zero role grants, then cleans all owned records/audits.

Remaining: simultaneous multi-user HTTP/browser edit races rely on existing domain
locking tests; network-failure ambiguity requires an explicit refresh; multi-shop
assignment is deliberately partial-capable. Production MFA/deployment hardening and
an exhaustive accessibility audit remain separate work.
