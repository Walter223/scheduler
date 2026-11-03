# Appointments and Calendar — UX Milestone 3

Presentation-only refinement of the existing bounded calendar and crew APIs.

- List, Day and Week retain their existing state values, query windows, status
  filters, UTC ordering, cursors and scope. The toolbar uses compact labeled native
  controls and Previous/Today/Next navigation. No appointments are fetched beyond
  the existing page/window and no totals are inferred from partial pages.
- Rows prioritize shop-local start time, snapshot duration, service, status,
  location, crew count/Lead and staffing needs. Main rows do not repeat technical
  UTC offsets. IANA zones remain visible; detail disclosure supplies start/end
  offsets independently, including DST changes during an appointment.
- Week is a seven-date agenda, not a proportional time-grid. Date groups have
  separate authorized shop lanes; empty dates are compact but remain explicit,
  with “on this page” wording. Simultaneous bookings in different shops are not
  rendered as conflict warnings. Partial-result and pagination messaging remains.
- Inline appointment details group schedule, service/vehicle and staffing, then
  the existing authorized crew operations. Accessible action names include the
  affected employee; visual labels are compact. The complete team is still loaded
  across its existing pages, with no arbitrary crew-size cap.
- No fetch, mutation, eligibility, CSRF, authorization or concurrency rules changed.
  Success/denial refreshes remain authoritative; busy locks, errors, cleanup and
  late-response guards are retained. Business/shop changes and access loss clear
  private data. Successful focus revalidation retains view/date/filter/selection.

Verification includes component tests (DST offsets, seven-date empty lanes,
partial pages, stale responses and crew operations) and real-Keycloak isolated
browser acceptance. Screenshot fixtures cover List/Day/Week/details at 1440, 1024,
768, 390 and 320px, including All Shops, multiple Detailers, canceled work and
long-label display stress. Screenshots under `/private/tmp/magnum-calendar-ux/`
contain only disposable fixture data, never login pages or credentials.

Existing restrictions remain: no dragging, proportional timeline, appointment
creation/cancellation/rescheduling, shift editing or calendar-provider integration.
Exhaustive cross-browser/screen-reader audits and real-browser multi-timezone/DST
and large-page permutations remain separate from deterministic component/domain
coverage. See ../backend/CALENDAR_API.md and ../backend/CREW_MANAGEMENT_UI.md.

Completion acceptance includes independent Owner and Shop Manager runs at every
requested width. Owner captures use the original filenames; Shop Manager captures
use the `shop-manager-` prefix, including an empty second assigned shop. Long shop,
service and vehicle labels are display-only stress on disposable authenticated
fixtures; they do not change persisted data or authorization. Keyboard Enter opens
appointment details, and focus revalidation retains the selected appointment/team.
