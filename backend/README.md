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

The schedule supports one appointment at a time across all service prices.
Pending and confirmed appointments occupy `[starts_at, starts_at + duration +
30 minutes)`. Cancelled and completed appointments do not block. Intervals that
only touch at their endpoints are allowed. Existing appointments use their
stored duration snapshots, even after catalog changes.

The GET result is informational. `Appointments.create_appointment/1` locks the
selected catalog row for consistent snapshots, revalidates the requested slot
inside its transaction, then inserts. A partial GiST exclusion constraint rejects
overlapping active intervals even across concurrent database connections or
writes that bypass the context. Ecto maps conflicts to a `starts_at` changeset
error. Client price, duration, and status remain ignored.

Run `mix ecto.migrate` before using the engine. The migration also validates
existing active appointments: overlapping historical rows must be reviewed
before it can succeed; the migration does not silently change bookings.

`mix test` includes a real-concurrency test using independent SQL connections
and committed, isolated fixtures with cleanup. The frontend is not connected
to availability yet; no appointment submission endpoint is added here.
