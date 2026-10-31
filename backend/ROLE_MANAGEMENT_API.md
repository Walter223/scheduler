# Customer access management — 4F-4B

Keycloak authenticates. Phoenix re-evaluates persisted account, tenant, membership
and complete role assignments. Employment classification describes work and privacy;
it never grants application authority. Business ownership access requires an active
Owner grant; historical Owner grants/classifications protect targets without granting
permissions. God Mode and deployment-operator bootstrap are separate, never HTTP roles.

## Fixed permission matrix

| Capability | Business Owner | Business Manager | Shop Manager | Employee |
|---|---|---|---|---|
| Business HR, permitted pay/finance | Yes | Yes; protected Owner pay excluded | No | No |
| Shop scheduling/appointments/teams | All active shops in own business | No | Explicit assigned shops | Own authorized current-period reads only |
| Assigned staff contact/current Detailer pay | Business-scoped | HR policy | Assigned shops; management pay excluded | Own authorized data only |
| `staff_access_read`, `staff_access_manage` | Business-wide | Restricted delegation below | No | No |
| Owner-only `access_manage`, membership lifecycle | Yes | No | No | No |
| Grant/revoke Employee or Shop Manager | Yes | Eligible non-self, non-Owner-protected targets | No | No |
| Grant/revoke Business Manager or Owner | Yes, last-eligible-Owner safeguards | No | No | No |

Owner permissions explicitly include the centralized Manager permission list plus
Owner capabilities. No duplicate Manager grant, employment change or login side
effect occurs. Removing either role leaves only independently qualifying remaining
grants. A business role cannot borrow scope from another business or shop grant.

Managers cannot modify their own roles or any same-business current/historical
Owner-grant target, or a user linked to current/historical Owner-classified
employment (including prior periods). Employee grants never erase this protection.
Managers cannot revoke/reactivate memberships. Account eligibility and active
membership are required for new grants. If linked employment exists, a new grant
requires an active employment period: membership reactivation alone cannot bypass
termination. Explicit future rehire periods permit preparing fresh grants; existing
period-sensitive read policies still enforce effective dates. Accounts with no
employment record can receive explicit grants; no employment/account/link is created.

## HTTP contract

Prefix `B=/api/admin/businesses/:business_id`.

| Method/path | Fields / result |
|---|---|
| GET `B/memberships` | Bounded permitted membership list |
| GET `B/role-grants` | Bounded permitted role list |
| POST `B/role-grants` | `membership_id`, fixed `role`, optional `shop_id`; 201 |
| POST `B/role-grants/:grant_id/revoke` | Empty JSON object; 200 |
| POST `B/memberships/:membership_id/revoke` | Owner only; empty JSON object; 200 |
| POST `B/memberships/:membership_id/reactivate` | Owner only; empty JSON object; 200 |

Business roles require no shop; Employee/Shop Manager require an active same-business
shop. All IDs are selectors, never authority. There is no membership creation,
first-Owner bootstrap, invitation, account activation, automatic restoration or
platform endpoint. Owner grants use the same protected RoleManagement workflow.

Reads accept only `limit` (1..100; default 50), `cursor`, `status` (`active` default
or `revoked`). SQL authorization precedes status filters, ID ordering and keyset
pagination. Cursors bind business, actor, collection and status; they are positions,
not authorization credentials. Every page rechecks current grants. Owners may see
all same-business membership/grant history. Managers see only active, eligible,
non-self/non-Owner-protected memberships and their Employee/Shop Manager grant
history. Upper-role and protected-target history cannot influence their pagination.

Lists return `data:{items,has_more,next_cursor}`. Mutations return `data:projection`.
Membership projection: `id,business_id,user_id,status,inserted_at,revoked_at`.
Grant projection: `id,business_id,membership_id,role,shop_id,status,inserted_at,revoked_at`.
No profiles, provider IDs/tokens, pay, employment contacts or internal audits appear.

Existing live opaque session authentication, no-store headers, private 64 KB JSON
parser, session-bound CSRF and exact Origin/controlled Referer checks apply. Reads
need no CSRF token. Writes reject unknown body/query keys and unsupported role values.
Errors: 401 `authentication_required`, generic 403 `forbidden`, 422 `invalid_input`,
409 `last_owner` / `duplicate_grant` / `ineligible_target`, 503 `operation_unavailable`.
Existing CSRF errors remain distinct. Unauthorized or cross-business targets return
403 without revealing existence. Revocation takes effect on the next request even
when the opaque browser session itself remains valid.

## Transactions and auditing

HTTP adapts references and delegates all writes to `Authorization.RoleManagement`.
Inside each transaction: business lock, stable ordered member user/membership/grant
locks, session lock/revalidation, current complete-grant/target-history authorization,
last-eligible-Owner check, mutation and atomic audit. HR classification/offboarding
and Owner bootstrap coordinate on the same business lock. Concurrent lower-role
delegation cannot outrun committed Owner protection or actor revocation. No transaction
holds an authorization decision valid beyond its current locked operation.

Revoked rows remain history; revoking membership cascades revocation with individual
audit events; reactivation restores none. Duplicate grants conflict deterministically.
Repeated revoke/reactivate retains the domain no-op policy. Audit failure rolls back
all writes. Expected RoleManagement denials commit a bounded denied event; HTTP
session/CSRF/shape/pre-scope failures never reach domain mutation and do not promise
an authorization audit. Database/audit outages cannot durably record their own failure.

No migrations or development-data changes. Existing tests cover last-Owner races on
independent PostgreSQL connections. New independent-connection races cover Manager/
Owner duplicate grants, Owner protection versus lower-role revocation, and Manager
revocation versus delegation. HTTP tests cover scopes/history, stale cookies, strict
projections, CSRF/origin/parser safety and atomic audit rollback. Full existing HR,
compensation and scheduling regression remains required at the checkpoint.

Remaining: no role UI, invitations, membership provisioning API, audit-reader API,
production MFA hardening or platform administration. No new real-browser suite;
transport security reuses the established browser/session boundary. Simultaneous
HTTP role mutations rely on the independently tested domain locking guarantees.
