defmodule SchedulerApi.UpcomingAppointmentsTest do
  use SchedulerApi.DataCase, async: true

  alias SchedulerApi.{Appointments, Catalog}
  alias SchedulerApi.Appointments.{Appointment, Availability}
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures

  @now ~U[2026-11-01 08:00:00Z]

  setup do
    price = service_price_fixture(%{duration_minutes: 15})
    %{price: price, attrs: booking_attrs(price, ~D[2026-11-02])}
  end

  test "includes future pending/confirmed and excludes past/cancelled/completed", context do
    pending = insert_booking(context, DateTime.add(@now, 7200), :pending)
    confirmed = insert_booking(context, DateTime.add(@now, 14_400), :confirmed)
    insert_booking(context, DateTime.add(@now, -7200), :pending)
    insert_booking(context, DateTime.add(@now, 21_600), :cancelled)
    insert_booking(context, DateTime.add(@now, 28_800), :completed)

    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now)
    assert ids(page) == [pending.id, confirmed.id]
    refute page.has_more
    assert page.next_cursor == nil
  end

  test "includes the exact-now boundary and truncates the explicit clock to seconds", context do
    appointment = insert_booking(context, @now)
    now = %{@now | microsecond: {999_999, 6}}
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: now)
    assert ids(page) == [appointment.id]

    assert {:ok, %{appointments: []}} =
             Appointments.list_upcoming_appointments(now: DateTime.add(@now, 1))
  end

  test "sorts chronologically rather than by insertion order", context do
    later = insert_booking(context, DateTime.add(@now, 14_400))
    earlier = insert_booking(context, DateTime.add(@now, 7200))
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now)
    assert ids(page) == [earlier.id, later.id]
  end

  test "orders by id at equal starts and uses that id as the cursor tie-breaker", context do
    earlier = insert_booking(context, DateTime.add(@now, 7200))
    appointment = insert_booking(context, DateTime.add(@now, 14_400))
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:scheduler_api, :repo, :query],
        fn _, _, metadata, pid ->
          if String.contains?(metadata.query, ~s(FROM "appointments")),
            do: send(pid, {:query, metadata.query})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # The production exclusion constraint forbids equal active starts. Keep it
    # intact: verify the emitted secondary ORDER BY and equal-time cursor branch.
    assert {:ok, page} =
             Appointments.list_upcoming_appointments(
               now: @now,
               cursor: cursor(appointment.starts_at, earlier.id)
             )

    assert ids(page) == [appointment.id]
    assert_receive {:query, sql}
    assert sql =~ ~r/ORDER BY a0\."starts_at", a0\."id"/

    for id <- [appointment.id, appointment.id + 1] do
      assert {:ok, %{appointments: []}} =
               Appointments.list_upcoming_appointments(
                 now: @now,
                 cursor: cursor(appointment.starts_at, id)
               )
    end
  end

  test "preloads service and vehicle size and retains stored snapshots", context do
    appointment = insert_booking(context, DateTime.add(@now, 7200))

    assert {:ok, _} =
             Catalog.update_service_price(context.price, %{
               price_cents: 9999,
               duration_minutes: 120
             })

    assert {:ok, service} =
             Catalog.update_service(
               Repo.get!(SchedulerApi.Catalog.Service, context.price.service_id),
               %{name: "Renamed package"}
             )

    assert {:ok, size} =
             Catalog.update_vehicle_size(
               Repo.get!(SchedulerApi.Catalog.VehicleSize, context.price.vehicle_size_id),
               %{name: "Renamed size"}
             )

    assert {:ok, %{appointments: [stored]}} = Appointments.list_upcoming_appointments(now: @now)
    assert Ecto.assoc_loaded?(stored.service_price)
    assert Ecto.assoc_loaded?(stored.service_price.service)
    assert Ecto.assoc_loaded?(stored.service_price.vehicle_size)
    assert stored.service_price.service.name == service.name
    assert stored.service_price.vehicle_size.name == size.name
    assert stored.price_cents == appointment.price_cents
    assert stored.duration_minutes == appointment.duration_minutes
    assert stored.service_price.price_cents == 9999
    assert stored.service_price.duration_minutes == 120
  end

  test "returns a complete empty page", _context do
    assert {:ok, %{appointments: [], has_more: false, next_cursor: nil}} =
             Appointments.list_upcoming_appointments(now: @now)
  end

  test "defaults to 50 appointments and exposes a continuation", context do
    appointments = insert_many(context, 51)
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now)
    assert ids(page) == appointments |> Enum.take(50) |> Enum.map(& &1.id)
    assert page.has_more
    assert is_binary(page.next_cursor)

    assert {:ok, last_page} =
             Appointments.list_upcoming_appointments(now: @now, cursor: page.next_cursor)

    assert ids(last_page) == [List.last(appointments).id]
    assert last_page.next_cursor == nil
  end

  test "custom limit and cursor return successive pages without repeats", context do
    [first, second, third] = insert_many(context, 3)
    assert {:ok, page1} = Appointments.list_upcoming_appointments(now: @now, limit: 1)
    assert ids(page1) == [first.id]

    assert {:ok, page2} =
             Appointments.list_upcoming_appointments(
               now: @now,
               limit: 1,
               cursor: page1.next_cursor
             )

    assert ids(page2) == [second.id]

    assert {:ok, page3} =
             Appointments.list_upcoming_appointments(
               now: @now,
               limit: 1,
               cursor: page2.next_cursor
             )

    assert ids(page3) == [third.id]
    refute page3.has_more
    assert page3.next_cursor == nil
  end

  test "a full final page has no cursor", context do
    insert_many(context, 2)
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now, limit: 2)
    assert length(page.appointments) == 2
    refute page.has_more
    assert page.next_cursor == nil
  end

  test "permits 100 results but rejects limits exceeding the maximum", context do
    insert_many(context, 101)
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now, limit: 100)
    assert length(page.appointments) == 100
    assert page.has_more
    assert {:error, %{field: :limit}} = Appointments.list_upcoming_appointments(limit: 101)
  end

  test "malformed limits return errors instead of raising" do
    for limit <- [0, -1, 1.5, "10", "bad", nil, true, [], %{}, 1_000_000] do
      assert {:error, %{field: :limit, message: message}} =
               Appointments.list_upcoming_appointments(limit: limit)

      assert is_binary(message)
    end
  end

  test "malformed cursors return errors instead of raising" do
    malformed =
      [
        "",
        "!invalid",
        1,
        [],
        %{},
        String.duplicate("a", 513),
        token("not json"),
        token(%{}),
        token([2, "2026-11-01T08:00:00Z", 1]),
        token([1, nil, 1]),
        token([1, "invalid", 1]),
        token([1, "2026-11-01T08:00:00", 1]),
        token([1, "2026-11-01T08:00:00.1Z", 1])
      ] ++
        for id <- [nil, "1", 1.5, 0, -1, 9_223_372_036_854_775_808],
            do: token([1, "2026-11-01T08:00:00Z", id])

    for value <- malformed do
      assert {:error, %{field: :cursor, message: message}} =
               Appointments.list_upcoming_appointments(cursor: value)

      assert is_binary(message)
    end
  end

  test "invalid clocks and option containers return errors" do
    for now <- [nil, "2026-11-01T08:00:00Z", ~N[2026-11-01 08:00:00], 123] do
      assert {:error, %{field: :now}} = Appointments.list_upcoming_appointments(now: now)
    end

    for options <- [nil, %{}, [1], "bad"] do
      assert {:error, %{field: :options}} = Appointments.list_upcoming_appointments(options)
    end
  end

  test "explicit now gives a deterministic cutoff independent of the real date", context do
    appointment = insert_booking(context, ~U[2020-01-01 00:00:00Z])
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: ~U[2020-01-01 00:00:00Z])
    assert ids(page) == [appointment.id]

    assert {:ok, %{appointments: []}} =
             Appointments.list_upcoming_appointments(now: ~U[2020-01-01 00:00:01Z])
  end

  test "the default clock selects future appointments", context do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    insert_booking(context, DateTime.add(now, -7200))
    upcoming = insert_booking(context, DateTime.add(now, 7200))
    assert {:ok, page} = Appointments.list_upcoming_appointments([])
    assert ids(page) == [upcoming.id]
  end

  test "uses instants across UTC midnight and Denver's repeated DST hour", context do
    first = insert_booking(context, ~U[2026-11-01 07:30:00Z])
    second = insert_booking(context, ~U[2026-11-01 08:30:00Z])

    assert Availability.local_datetime(first.starts_at) ==
             Availability.local_datetime(second.starts_at)

    assert {:ok, page} = Appointments.list_upcoming_appointments(now: @now)
    assert ids(page) == [second.id]

    midnight = insert_booking(context, ~U[2026-11-02 00:30:00Z])
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: midnight.starts_at)
    assert ids(page) == [midnight.id]

    assert NaiveDateTime.to_date(Availability.local_datetime(midnight.starts_at)) ==
             ~D[2026-11-01]
  end

  test "does not apply Sunday, business hours, buffer, or 90-day booking restrictions", context do
    # Sunday at 01:00 Denver; then a start far beyond the booking horizon.
    sunday = insert_booking(context, ~U[2026-11-01 07:00:00Z])
    distant = insert_booking(context, DateTime.add(@now, 120 * 86_400))
    assert {:ok, page} = Appointments.list_upcoming_appointments(now: ~U[2026-11-01 06:59:59Z])
    assert ids(page) == [sunday.id, distant.id]
  end

  defp insert_booking(context, starts_at, status \\ :pending) do
    # Controlled query fixtures bypass creation's booking-window validation,
    # while retaining every production schema and database constraint.
    %Appointment{
      business_id: context.price.business_id,
      shop_id: context.price.shop_id,
      price_cents: context.price.price_cents,
      duration_minutes: context.price.duration_minutes,
      status: status
    }
    |> Appointment.changeset(Map.put(context.attrs, :starts_at, starts_at))
    |> Repo.insert!()
  end

  defp insert_many(context, count) do
    for index <- 1..count, do: insert_booking(context, DateTime.add(@now, index * 7200))
  end

  defp ids(page), do: Enum.map(page.appointments, & &1.id)
  defp cursor(starts_at, id), do: token([1, DateTime.to_iso8601(starts_at), id])
  defp token(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
