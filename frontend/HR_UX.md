# Employee directory and profile presentation

UX Milestone 2 uses the existing HR endpoints and server-derived capabilities.
There are no persistence, authorization or lifecycle-policy changes.

- One semantic employee table contains name, employment classification, status,
  concise shop summary and a compact profile action. Phone layouts stack those same
  records without duplicating DOM, fetching unbounded lists or truncating names.
  Contact fields and period history are not rendered in directory rows.
- HR users open an Employee details modal drawer: overview, contacts, assignments,
  employment timeline and management actions. Selected historical periods remain
  read-only until Return to current profile. Stable employee and period IDs remain
  distinct. Existing server name/classification/status filters and cursors are retained.
- Shop Managers open only a current-shop contact drawer from the already authorized
  roster projection, with no HR profile/history request or mutation controls.
- Native dialog showModal supplies modality. A small shared hook handles nested
  scroll locks, deterministic Tab/Shift-Tab wrapping and focus restoration without
  scrolling the page. If a mutation removes the triggering row, focus returns to
  the Admin workspace instead. Escape closes only the top dialog when cancellation
  is allowed; pending saves remain locked. Native lifecycle confirmations are retained.
- Successful window-focus revalidation preserves mounted drawer/history/filter state.
  Explicit tenant changes, access loss and session failures still clear private data
  and abort/discard late responses. No protected data is written to browser storage.

Verification uses component tests and real-Keycloak disposable browser fixtures.
The latter includes every HR mutation, role distinctions, historical periods,
modal focus/inert-background behavior and retained state after focus revalidation.
Maximum field lengths and 20-record pages have component coverage; long name/contact
screenshots use display-only stress in a disposable authenticated browser, without
mutating development records. No screen-reader certification is claimed.

Reproduce frontend checks with npm run test:component, npm run lint and npm run build.
Run npm run test:auth separately with free isolated ports 4002/5174, following
../backend/AUTHENTICATION.md. Credential-free screenshots are written under
/private/tmp/magnum-hr-ux/ (directory/profile at 1440, 768, 390 and/or 320px,
create forms, historical periods, termination/rehire and long-field stress).
No login forms, credentials, session tokens or cookies are captured.
