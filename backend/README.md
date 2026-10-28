# SchedulerApi

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Availability

`GET /api/availability?date=2026-10-24&service_price_id=4` returns Denver-local
start times using the selected catalog duration. For a 90-minute service with
no blocking appointments:

```json
{
  "date": "2026-10-24",
  "service_price_id": 4,
  "duration_minutes": 90,
  "available_times": ["09:00", "09:30", "10:00", "10:30", "11:00", "11:30", "12:00", "12:30", "13:00", "13:30", "14:00", "14:30", "15:00", "15:30", "16:00"]
}
```

Dates must be Monday–Saturday, from today through today + 90 days inclusive,
using America/Denver's calendar date. Starts are every 30 minutes from 09:00;
the entire service plus a 30-minute buffer must finish by 18:00. Same-day
starts must be strictly later than now. A valid day with no slots returns
`200` with `available_times: []`.

Malformed/missing input, past dates, Sundays, and dates beyond the window return
`422`; unknown service prices return `404`. Errors have a stable code, field,
and message, for example:

```json
{"error": {"field": "date", "code": "closed_sunday", "message": "we are closed on Sundays"}}
```

PostgreSQL's IANA timezone rules handle Denver DST; timestamps on appointments
remain UTC. No new timezone package is required.

Each shop supports one appointment at a time across its service prices.
Pending and confirmed appointments occupy `[starts_at, starts_at + duration +
30 minutes)`. Cancelled and completed appointments do not block. Intervals that
only touch at their endpoints are allowed. Existing appointments use their
stored duration snapshots, even after catalog changes.

The GET result is informational. `Appointments.create_appointment/1` first takes
an exclusive transaction-level advisory lock for the selected shop, then
locks the selected catalog row for consistent snapshots, revalidates the requested
slot, and inserts in the same transaction. The next creator waits until commit or
rollback, then rechecks against the committed booking and returns a normal
`starts_at` validation error for an unavailable slot. This avoids deadlocks between
concurrent GiST exclusion checks. The advisory key is shop-specific; employee/bay scheduling is not implemented.
A partial GiST exclusion constraint remains the final safety net and rejects
overlapping active intervals within a shop even across concurrent database connections or
writes that bypass the context. Ecto maps conflicts to a `starts_at` changeset
error. Client price, duration, and status remain ignored.

Run `mix ecto.migrate` before using the engine. The migration also validates
existing active appointments: overlapping historical rows must be reviewed
before it can succeed; the migration does not silently change bookings.

`mix test` includes a real-concurrency test using independent SQL connections
and committed, isolated fixtures with cleanup. Public availability and booking endpoints retain their existing frontend contracts.


## Upcoming appointments API — development only

`GET /api/admin/appointments` lists upcoming pending/confirmed appointments in
`starts_at`, then ID ascending order. **This endpoint is not production-ready:**
it exposes customer names, contact details, and notes without authentication or
authorization. `/api/admin` is only a URL prefix, not access control. The route
is currently registered in all environments; development-only use is a policy,
not an environment restriction. Do not expose it publicly or deploy it for real
customer access until server-side admin authentication and authorization exist.
No frontend secret or cursor grants access control.

Optional query parameters:

- `limit`: integer from 1 through 100; defaults to 50. Larger values are rejected.
- `cursor`: the opaque `meta.next_cursor` from the preceding response. Pass it
  unchanged, URL-encoded. Pagination uses `(starts_at, id)`, not offsets.

Example local request:

```sh
curl 'http://localhost:4000/api/admin/appointments?limit=25'
```

The `200` response contains `appointments` and `meta`:

```json
{
  "appointments": [],
  "meta": {"timezone": "America/Denver", "has_more": false, "next_cursor": null}
}
```

Each appointment contains `id`, `service_price_id`, `customer_first_name`,
`customer_last_name`, `customer_email`, `customer_phone`, `vehicle_make`,
`vehicle_model`, `service_name`, `vehicle_size`, `starts_at`, `duration_minutes`,
`price_cents`, `notes`, and `status`. Timestamps are UTC ISO 8601 strings (`Z`);
America/Denver is the display timezone. Service/size names reflect current
catalog associations; price/duration are the appointment's stored snapshots.
`notes` may be null. `has_more` indicates another page and `next_cursor` is null
on the final page. Each request uses the current server clock; pagination is
not a frozen snapshot. A client `now` parameter does not override that clock.

Malformed limits/cursors return `422`, for example:

```json
{"error": {"field": "limit", "message": "must be an integer from 1 to 100"}}
```

The listing does not apply availability business hours, buffers, Sundays, or
booking-window rules. Existing `POST /api/appointments` payloads, responses,
validation, pricing snapshots, and concurrency protection are unchanged.

## Stage 1 organization ownership

The organization migration creates one `Magnum Detailing` business
(`magnum-detailing`) and one `Magnum Detailing Default Location` shop (`default`),
with timezone `America/Denver`. No physical address is assumed. Lifecycle status
is `active` or `archived`; it is metadata in this stage, not a new booking rule.

Ownership is added nullable, backfilled, checked against a transaction-local
snapshot of every original row/field, and then made non-null with foreign keys.
IDs, timestamps, appointment snapshots, customer details, notes, and statuses are
preserved. Composite foreign keys keep shops, services, vehicle sizes, prices,
and appointments in the same business/shop. Catalog uniqueness is business-scoped;
service-price uniqueness is shop-scoped. Deleting referenced tenants is restricted.
The migration requires a reviewed rollback rather than silently discarding tenant
identity. Historical migrations are unchanged.

`Organizations.default_business!/0` and `default_shop!/0` resolve the known tenant
by stable slugs. Existing catalog creation assigns that tenant on trusted structs;
appointment ownership comes from its selected service price. Ownership is not
accepted from client attrs, and public request/response formats are unchanged.
Seeds can be rerun: they insert missing default catalog entries without overwriting
existing IDs, values, or timestamps.

## Coordinated shop-scoped scheduling

All public entry points resolve `Organizations.default_shop!/0` server-side using
business slug `magnum-detailing` and shop slug `default`. No first-row fallback or
request-supplied business/shop selection exists. The public catalog, availability,
booking creation, appointment lookup/listing, and admin listing use this boundary.
Services must have an offering in that shop; returned prices must match its shop,
business, service, and vehicle-size ownership. Foreign-shop price IDs produce the
existing missing-price errors. Ownership attrs cannot override the validated price.

Trusted internal callers can pass a persisted `Shop` explicitly to Catalog and
Appointments overloads and `Availability.get_for_shop/4`. These are business/data
boundaries, not authentication or authorization. HTTP controllers do not accept
that boundary from query/body params. Future authorization must resolve an allowed
shop before calling these functions. Queries filter shop/business before cursor
pagination; cursors remain positions, never access credentials. Names come from
the current catalog; appointment price and duration remain snapshots. Time/date
rules remain America/Denver in this milestone; other shop timezones are not enabled.

Each shop has one shared scheduling resource. The negative single-bigint advisory
key range is reserved for scheduling, with `key = -shop.id`. This is injective for
positive PostgreSQL bigint IDs, including IDs beyond 32 bits; no hash, truncation,
service price, customer, or user is involved. PostgreSQL's two-integer lock overload
only accepts 32-bit components. Other features must not reuse this negative key
namespace. The transaction acquires the shop lock before catalog `FOR SHARE`
locks, the authoritative availability recheck, and insertion. Future platform
access must use the same path and cannot bypass scheduling safety.

The new overlap migration installs `btree_gist` and changes the existing
`appointments_no_active_overlap` constraint to compare `shop_id WITH =` and the
same half-open occupied range (`starts_at` through duration plus 30 minutes).
Only pending/confirmed rows participate. Different shops may overlap; same-shop
active overlaps remain database errors even when the application is bypassed.
All prior foreign-key ownership consistency constraints remain in force.

**Deployment coordination:** drain/stop booking writers, run `mix ecto.migrate`,
deploy the matching application version, and resume writes. Old and new advisory
key schemes must not serve writes together. `btree_gist` installation requires
the appropriate database privileges. The migration holds an exclusive table lock,
adds the new constraint before dropping the old one, and retains the constraint
name in one transaction. There is no committed interval without overlap safety,
and appointment rows/IDs/data/timestamps are untouched. Allow time for constraint
validation/index building on a large table. Rollback to global scheduling fails
safely if cross-shop overlaps now exist; review data rather than deleting bookings.

HTTP authentication, memberships, employees, frontend shop selection, and admin
authorization remain out of scope. `/api/admin/appointments` is still development
only and unauthenticated; shop filtering is not a replacement for access control.

## Account identity and session primitives

See [ACCOUNTS.md](ACCOUNTS.md) for the internal Accounts context, verified-identity
boundary, pending-user lifecycle, hashed revocable sessions and timeout policy.
These primitives add no login/session routes or application authorization and
work without Keycloak. Provider-token storage and OIDC integration are deferred.
