# Employment access requirements and test matrix

Pre-4E-2B review. **Coverage means assertions inspected, not tests executed for
this documentation change.** Partial coverage is not milestone acceptance.
Keycloak authenticates; Phoenix authorizes each complete business/shop grant.
Employment, login identity, classification and RBAC remain separate.

## Required scenarios

| # | Permanent requirement | Current coverage | Missing acceptance coverage |
|---|---|---|---|
| 1 | One user employed by A and B, with different Owners: records, pay, work, permissions and termination are independent. | **Partial.** [Employment access][access]: `same person can self-serve distinct businesses only through each matching assignment`; [Work schedules][shifts]: `one linked person reads each business only through its own matching role and assignment`. [Offboarding][offboarding]: `unrelated business membership and global session remain intact`. | One fixture with two actual linked employments, distinct Owners, pay/jobs/shifts in both: terminate A, deny A access, prove B employment, work, pay, grants and session access unchanged. Existing offboarding test adds a B membership, not a second employment. |
| 2 | One employment at two shops: explicit assignments/grants; ending one shop does not terminate the other; employee shifts/jobs cannot overlap across shops. | **Partial.** [Employment persistence][persistence]: `multiple shops, duplicate active assignments and ended assignment history`; [Shift concurrency][shift-races]: independent-connection cross-shop overlap tests; [Teams][teams]: `a member's cross-shop overlapping job blocks only that employee, not the whole team`. | Secure HR end-one-shop plus authorized reads of the other; secure offboarding with future work in both shops and unrelated employees preserved. |
| 3 | Two businesses owned by the same human remain separate tenants. Owning A never supplies scope for B; independently granted B ownership still cannot merge their records or lifecycle. | **Partial.** [Authorization][authorization]: `owner is business-wide but never cross-tenant`; [Compensation][pay]: unrelated-business Owner roles stay business-local. | Same user explicitly owns both A and B; verify tenant-specific HR/pay/rosters, spoofed selectors, pagination and terminating A employment never change B. Existing tests do not cover this full topology. |
| 4 | On successful termination commit, revoke all target-business grants/membership; stale sessions cannot retain that access. Other-business access and global sessions remain usable. | **Partial.** [Offboarding][offboarding] checks target membership revocation and unrelated membership/session survival. [Employment access][access] checks next-query revocation and no restored grant on membership reactivation. | Present the **same pre-termination cookie** to protected A/B HTTP requests after offboarding: A denied, B authorized. Assert each affected target grant is revoked and all own-work/pay projections deny A. Already-authorized in-flight reads are distinct from requests begun after commit. |
| 5 | Owners may terminate HR employees. Business Managers/HR cannot terminate Business Owners or bypass last-Owner safeguards. | **Core hardening covered.** [Owner termination][owner-termination] tests current/historical Owner classification without grants, Employee/revoked Owner grants, non-Owner management history, stale actors, and Owner termination of HR employment preserving another business. [Owner races][owner-races] tests classification downgrade, grant creation and revocation against termination on independent connections. [Offboarding][offboarding] retains last-Owner refusal/rollback; [Role races][role-races] retains last-Owner grant-removal races. | Simultaneous secure offboarding of two Owners remains untested end to end. Current and historical Owner classification/grants now restrict HR termination; they never grant permissions. Explicit Owner-managed transitions still require a current qualifying Owner grant and last-Owner enforcement. |
| 6 | Rehire retains full prior records for authorized HR, but employee self-service cannot automatically see prior periods, compensation, shifts or jobs. | **Context-level rehire implemented; 4F HTTP coverage pending.** [Rehire tests][rehire] verify effective-period own-pay/work/shift isolation, HR history, stable identity, and no restoration. [Offboarding][offboarding] preserves history and tests former-HR visibility. [Pay][pay] tests ended history is HR-only. [HR tests][hr] protect historical management pay after reclassification. | 4F: authenticated HTTP/cookie tests of prior-period IDs and future timeline/cursor endpoints. Context tests now verify active-period projections, old open-ended pay and guessed shift/job IDs. |
| 7 | Rehire restores no memberships, grants, rates, shifts or shop assignments automatically. All new activation/work/pay decisions require explicit authorized workflows. | **Context-level covered.** [Rehire tests][rehire] verify zero restoration before and after explicitly granted new-period access. [Roles][roles]: `membership reactivation restores no revoked roles`. [Employment persistence][persistence] rejects reactivating ended employment/assignment rows. | 4F: exercise the same old browser cookie and repeated real login after rehire. Context tests now cover no restoration, explicit membership reactivation without grants, and fresh per-period authorization. |
| 8 | Concurrent/repeated lifecycle operations retain authorization, history and atomic audits; failures leave no partial effects. | **Partial.** [HR races][hr-races]: `two offboarding requests create exactly one termination and historical audit`, offboarding-versus-shift creation. [Offboarding][offboarding] covers final, scheduling and RBAC audit rollback, legacy-ended denial and repeat no-op. | Rehire duplicate, HR grant-revocation and explicit membership-reactivation races are covered by context tests. Remaining: secure offboarding-versus-job/lead changes, simultaneous last-Owner offboarding, full two-business concurrency and stale-cookie HTTP races. Existing job-termination race tests use the older persistence helper, not secure offboarding. |

## Decisions and safeguards before 4E-2B

- Owner termination denial now includes persisted current/historical Owner
  classifications and same-business Owner grant history. Retain this restriction
  across future rehire/period designs; classification must never become authority.
- Implemented model: immutable employment rows are periods, anchored by stable
  `employee_id`. Root identity is unique per linked user/business; active periods
  and dates cannot overlap. See [rehire design](../backend/REHIRE.md).
- Bind future self-service pay/work/history queries to the authorized employment
  period, before projection/pagination. Existing employment-ID-based queries and
  open-ended rates are not proof of rehire isolation. Preserve sticky management
  compensation restrictions; never downgrade privacy through an Employee grant.
- Keep current explicit refusals for in-progress work, incompatible future dates
  and legacy terminations until a reviewed reconciliation policy exists. Do not
  silently delete work or claim offboarding succeeded.

## Future Admin UI acceptance criteria — not implemented

- Business selector lists only currently authorized businesses. Same-owner tenants
  remain distinct. Switching business clears stale shop, employee and timeline
  state; requests and cursors are scoped server-side.
- Shop selectors offer only authorized shops in the chosen business. Multi-shop
  employment appears once in business rosters, with explicit shop relationships.
  Business Manager HR authority does not imply shop scheduling authority.
- Separate **Active Employees** and **Former Employees** sections. Former records
  are retained HR projections with pagination, not restored active permissions.
- Historical timelines show employment periods, classifications, shop assignments
  and authorized lifecycle events. Compensation needs its separate permission;
  never serialize unrestricted schemas or expose credentials/payroll identifiers.
- Rehire confirmation explicitly lists what is retained for HR, hidden from employee
  self-service, and **not restored**. No automatic prior-pay/work/access checkbox
  defaults. Prior-period IDs remain inaccessible through employee routes.
- Role-restricted actions: Owner HR management, permitted Business Manager HR,
  Shop Manager operations at assigned shops only, employee own/current-period
  self-service. Owner termination and last-Owner refusals are explicit. Hidden
  buttons do not replace backend checks; stale sessions receive safe denial.
- Test loading/error/revoked-access states, selector races, tenant switches,
  repeat submissions and audit-failure rollback. No UI/E2E acceptance tests exist
  for these future screens yet.

[access]: ../backend/test/scheduler_api/employment_access_test.exs
[persistence]: ../backend/test/scheduler_api/employment_test.exs
[shifts]: ../backend/test/scheduler_api/work_schedules_test.exs
[shift-races]: ../backend/test/scheduler_api/work_shift_concurrency_test.exs
[teams]: ../backend/test/scheduler_api/appointment_teams_test.exs
[offboarding]: ../backend/test/scheduler_api/offboarding_test.exs
[authorization]: ../backend/test/scheduler_api/authorization_test.exs
[pay]: ../backend/test/scheduler_api/compensation_test.exs
[roles]: ../backend/test/scheduler_api/role_management_test.exs
[role-races]: ../backend/test/scheduler_api/role_management_concurrency_test.exs
[hr]: ../backend/test/scheduler_api/employment_hr_test.exs
[hr-races]: ../backend/test/scheduler_api/employment_hr_concurrency_test.exs

[owner-termination]: ../backend/test/scheduler_api/owner_termination_test.exs
[owner-races]: ../backend/test/scheduler_api/owner_termination_concurrency_test.exs

[rehire]: ../backend/test/scheduler_api/rehire_test.exs

## 4F-1 HTTP coverage update

[HR read API contract](../backend/HR_READ_API.md) and
[controller tests](../backend/test/scheduler_api_web/controllers/employee_controller_test.exs)
now cover the same stale cookie losing terminated-business HR access while retaining
unrelated-business HR access; distinct/same-human Owners; scoped shop rosters;
current/former and rehire timelines; prior-period admin denial for Employees;
stable-ID/period-ID mismatches; and scope-bound cursor isolation. These are actual
Phoenix HTTP/session tests, not a real Keycloak browser login. Future browser/UI
selector races and self-service HTTP surfaces remain separate acceptance gaps.

4F-2 adds [protected HR writes](../backend/HR_WRITE_API.md) with HTTP tests of
CSRF, field/tenant spoofing, Owner restrictions, atomic rollback and repeated
lifecycle mutations. Simultaneous HTTP races remain deferred; existing
independent-connection domain tests are the concurrency evidence.
