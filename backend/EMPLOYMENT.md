# Employment persistence — Milestone 4A

`SchedulerApi.Employment` owns internal employment records and shop assignments.
These functions are not authorized HR APIs: future callers must enforce Phoenix
HR permissions before exposing them. No HTTP routes, contact projections,
compensation, schedules, jobs or new permissions are implemented.

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
