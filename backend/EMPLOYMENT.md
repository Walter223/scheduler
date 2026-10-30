# Employment — persistence and authorized reads

`SchedulerApi.Employment` owns internal employment records and shop assignments.
Milestone 4A mutation functions remain trusted persistence primitives, not
authorized HR APIs. Milestone 4B adds the authorized, field-projected reads below.
Milestone 4C adds [compensation persistence and access](COMPENSATION.md). No HTTP
routes, contact mutations, schedules or jobs are implemented.

## Identity and ownership

- `employments` belongs to one business; first/last names are independently supplied
  employment data, not synchronized account profile fields.
- `user_id` is nullable. Multiple unlinked records are allowed. A linked user has
  one durable record per business, including ended records; the same user can
  have separate records in multiple businesses.
- `create_employment(business, attrs, user: user)` is the only current operation
  accepting a user reference. It reloads persisted eligibility through a database
  guard: active account, verified email, matching active business membership.
  No role is required or granted. Stale structs and ownership fields in attrs
  cannot bypass validation. No email matching, login linking, reassociation,
  invitation or linking endpoint exists. Later linking needs a separately
  authorized/audited workflow; the database allows only an initial eligible link,
  never replacing or removing an existing link.
- Membership/account suspension or revocation does not silently terminate
  employment or alter classification. It continues to block application access
  under existing authentication/authorization rules.

## Classification and lifecycle

Required primary classifications are `detailer`, `shop_manager`,
`business_manager`, `business_owner`. They grant **zero permissions** and never
follow RBAC grants. Classification, business and start date are immutable in this
foundation; audited classification corrections/promotions are future work.
Employee grants cannot downgrade a management classification.

Employment and assignments use explicit `active` / `ended` statuses. `starts_on`
is required; `ends_on` exists only when ended and cannot precede the start.
Dates are inclusive calendar dates, not scheduled status changes. Status changes
happen when explicitly invoked; future dates do not create background jobs.

`assign_shop(employment, shop, %{starts_on: date})` reloads ownership/status and
requires an active business, shop and employment. Composite foreign keys enforce
matching businesses. Assignment starts cannot precede employment starts.
A partial unique index permits only one active assignment per employment/shop.

`end_shop_assignment(assignment, date)` retains terminal history; assigning the
shop again creates a new row. `end_employment(employment, date)` locks the parent,
closes active assignments and ends employment atomically. Invalid dates, including
an end before a future assignment starts or before historical assignment ends,
reject the entire operation. Ending again with the same date is idempotent;
changing ended history or reactivating it is rejected. Rehire and future-assignment
cancellation require separate future lifecycle design, not implicit restoration.

`get_employment(business, id)`, `list_employments(business)` and
`list_shop_assignments(business, employment)` are business-filtered internal reads,
not authorization decisions or safe customer-facing projections.

## Integrity and verification

Database checks, composite/restrictive foreign keys and triggers retain ownership,
linked identity, classification and ended history. Assignment creation and
termination serialize on the employment row, including direct SQL insertion;
there are no sleep/retry mechanisms. Lifecycle operations lock parent before child.

The additive migration creates empty tables and backfills nothing. It does not
change accounts, RBAC, catalog, appointments or shop scheduling. Down migration
removes only these new tables/functions; do not roll it back after real employment
data exists without a reviewed preservation/export plan.

Focused checks:

```sh
mix test test/scheduler_api/employment_test.exs test/scheduler_api/employment_concurrency_test.exs
```

Tests use sandbox rollback or positively owned, independently connected test
fixtures with cleanup. No developer accounts receive employment or grants.

## Authorized roster/contact reads — Milestone 4B

- `list_business_roster(actor, business, opts)` uses `employment_private_read`:
  Business Owners/Managers get current business-wide employment/contact maps,
  including unlinked and unassigned staff. It does not confer shop operations.
- `list_shop_roster(actor, shop, opts)` uses `assigned_employee_contact_read`:
  Owners/Shop Managers get only current staff assigned to that authorized shop.
  A Business Manager uses the HR roster, not this operational shop capability.
  Management staff contacts are allowed; compensation is never returned.
- `get_own_employment(actor, business, opts)` uses `employment_own_read` and
  requires the persisted employment's `user_id` to match the eligible actor.
  Employee grants also require an active, current assignment at the same granted
  shop. The existing role mapping is unchanged: Employee and Business Owner have
  this permission; managers use their respective roster paths unless independently
  granted Employee access. Employee grants never change primary classification.

Reads return only `id`, `business_id`, `first_name`, `last_name`, `classification`,
`starts_on`, `phone`, `email`, `home_address`. No schemas, user IDs, identity claims,
other shop assignments, sessions, government/bank/payroll identifiers, compensation
or audit data are serialized. Future fields remain excluded by the SQL allowlist.
Phone/email/home address are nullable, business-specific columns (32/320/1000
characters); existing values remain NULL. There is no profile/email-name fallback,
automatic sync or new writer, including through the existing creation changeset.

Rosters return `{:ok, %{employments: maps, has_more: boolean, next_cursor: token}}`.
They order by employment ID ascending and support `:limit` (default 50, max 100)
and `:cursor` (unsigned Base64URL `[1, id]`, position only). Authorization, target
ownership, lifecycle/date filtering and deduplication run in SQL before pagination;
unauthorized records cannot influence page metadata. Empty authorized rosters are
successful. Missing grants/own records return `{:error, :forbidden}`; malformed
options return `:invalid_options`, `:invalid_limit`, `:invalid_cursor` or
`:invalid_clock` errors.

`:now` is an internal trusted clock seam, **never** a future request parameter.
Current employment/assignment means active status and start date reached using
Magnum's existing America/Denver calendar. Ended records are excluded immediately,
consistent with explicit 4A transitions. Future-hire/history browsing is not added.
Archived shops invalidate shop-scoped grants; archived businesses invalidate all
reads. Active business-wide HR employment remains visible even if its shop or
linked account is inactive: suspending an account is not employment termination.
Self-service always checks the actor's current eligibility.

`Authorization.authorize(actor, action, employment_reference)` reloads record
ownership through these queries. `employment_scopes_query/2` and
`authorized_employment_ids_query/3` retain complete grant scopes; never materialize
or flatten them into cached role/shop sets. Authentication is still a separate
caller responsibility: future adapters must take the actor from the authenticated
session, not HTTP identity parameters. Compensation uses the separate guarded queries in [COMPENSATION.md](COMPENSATION.md);
assigned-job/schedule resolvers remain denied. Historical raw 4A retrieval helpers are internal only;
they are not substitutes for these authorized projections.

Focused access verification: `mix test test/scheduler_api/employment_access_test.exs`.
