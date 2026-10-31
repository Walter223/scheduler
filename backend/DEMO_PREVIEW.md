# Local Admin demo fixture

Development operator only, from `backend/`:

```sh
MAGNUM_OIDC_ENABLED=false mix magnum.demo_preview --owner-user-id 1 --dry-run
MAGNUM_OIDC_ENABLED=false mix magnum.demo_preview --owner-user-id 1 --apply
MAGNUM_OIDC_ENABLED=false mix magnum.demo_preview --owner-user-id 1 --verify
```

OIDC is disabled only in this separate command process. The running authenticated
backend/Vite remain untouched. The CLI requires MIX_ENV=dev, scheduler_api_dev and
current active verified Owner authority for business 1. It never creates users,
activates accounts or assigns RBAC grants. Do not use it against production.

Version `magnum-demo-preview-v1` creates two reserved demo shop slugs, five visibly
fictional employment records (three Detailers, one Shop Manager, one Former), seven
employment/shop relationships, one DEMO service/vehicle size and one price per demo
shop, three covering shifts and six pending appointments. First shop crews are
2/1/0; second shop crews are 1/0/0. Assigned crews have explicit Leads. Employment
classification does not confer login access or permissions. Contact addresses are
fictional and emails use the reserved `.invalid` suffix. No messages are sent.

First apply chooses today before 14:00 Denver time or the next open booking day;
Sunday is skipped. Slots start at the first future supported half-hour and then
one hour apart. Shifts cover 09:00–18:00, including every 30-minute appointment's
30-minute buffer. Original shop configuration, public catalog and appointments are
unchanged. Booking hours remain the existing domain policy, not new shop settings.

The whole fixture is one business-locked transaction. It creates an internal
short-lived opaque Owner credential, uses audited HR/offboarding, WorkSchedules
and JobAssignments operations, and revokes the credential before commit. No token
is exposed or usable by the browser. Catalog/shop rows use existing ownership
changesets and constraints. Any failure rolls back rows, audits and the command's
session. Existing Owner browser sessions remain valid.

Repeat apply sees the reserved shops and performs no writes. Partial/colliding
shop identifiers are rejected; existing fixture data is never repaired, overwritten
or moved to today's date. Do not rename reserved fixture identifiers. Reruns are
not a maintenance/reconciliation operation. Preview dates are printed on creation.

## Preview and limitations

Open http://localhost:5173/admin and refresh access to discover the demo shops.
Employees/HR shows active/former records and retained history. Select either demo
shop, then Appointments and calendar; choose the printed date and day/week view.
Open the first appointment for the two-person team and Lead controls. Dashboard
is strictly **today**, so future demo bookings appear there only on their actual
local date. It intentionally shows no invented Sunday appointments.

There is no supported appointment-cancellation domain operation. This fixture does
not bypass that boundary with direct status updates; canceled example appointments
are **not created**. No compensation, invitations or identity accounts are seeded.
Verify uses the current Owner's authorized roster, history, dashboard, calendar and
team reads. It does not manufacture an HTTP/browser login session.

## Retention-safe cleanup

No delete/reset/automatic cleanup command is provided. Demo history is real retained
development history and must not be hard-deleted. Authorized termination through HR
can offboard demo employees (closing future work/shifts and shop assignments under
existing blockers/audits). Existing appointments remain. Hiding demo shops by archival
requires a separately reviewed local operator action after outstanding-work review;
this fixture does not implement or silently perform it. Archive/termination must
never remove the original shop, existing appointments, Owner access or audit history.
