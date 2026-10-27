defmodule SchedulerApi.AvailabilityTest do
  use SchedulerApi.DataCase, async: true

  alias SchedulerApi.{Appointments, Catalog}
  alias SchedulerApi.Appointments.{Appointment, Availability}
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures

  @now ~U[2026-10-19 14:00:00Z]
  @date ~D[2026-10-20]

  setup do
    price = service_price_fixture(%{duration_minutes: 90})
    %{price: price}
  end

  test "normal day has half-hour starts and includes an exact closing fit", %{price: price} do
    assert {:ok, result} = Availability.get("2026-10-20", price.id, @now)
    assert result.date == "2026-10-20"
    assert result.service_price_id == price.id
    assert result.duration_minutes == 90

    assert result.available_times ==
             for(
               hour <- 9..16,
               minute <- ["00", "30"],
               do: "#{String.pad_leading(to_string(hour), 2, "0")}:#{minute}"
             )
             |> Enum.reject(&(&1 == "16:30"))

    assert "16:00" in result.available_times
    refute "16:30" in result.available_times
  end

  test "rejects invalid, missing, past, out-of-window, and Sunday dates", %{price: price} do
    for {date, code} <- [
          {"2026-02-30", :invalid_date},
          {nil, :invalid_date},
          {[], :invalid_date},
          {"2026-10-18", :past_date},
          {"2027-01-19", :outside_booking_window},
          {"2026-10-25", :closed_sunday}
        ] do
      assert {:error, %{field: :date, code: ^code}} = Availability.get(date, price.id, @now)
    end
  end

  test "accepts the 90th day when open and rejects day 91", %{price: price} do
    # October 20 + 90 days is Monday January 18, 2027.
    now = ~U[2026-10-20 14:00:00Z]
    assert {:ok, _} = Availability.get("2027-01-18", price.id, now)

    assert {:error, %{code: :outside_booking_window}} =
             Availability.get("2027-01-19", price.id, now)
  end

  test "validates IDs without raising on malformed or oversized inputs" do
    assert {:error, %{code: :not_found}} = Availability.get(@date, 9_000_000_000, @now)

    for id <- [nil, "bad", "1abc", "999999999999999999999999999999", [], 0, -1] do
      assert {:error, %{code: :invalid_service_price_id}} = Availability.get(@date, id, @now)
    end
  end

  test "Saturday is open and a fully occupied day returns no slots", %{price: price} do
    assert {:ok, result} = Availability.get("2026-10-24", price.id, @now)
    assert hd(result.available_times) == "09:00"
    {opens, _} = Availability.business_hours(@date)

    %Appointment{
      business_id: price.business_id,
      shop_id: price.shop_id,
      price_cents: price.price_cents,
      duration_minutes: 510
    }
    |> Appointment.changeset(%{booking_attrs(price, @date) | starts_at: opens})
    |> Repo.insert!()

    assert {:ok, %{available_times: []}} = Availability.get(@date, price.id, @now)
  end

  test "longer services remove late starts and an oversized service has no slots", %{price: price} do
    assert {:ok, _} = Catalog.update_service_price(price, %{duration_minutes: 150})
    assert {:ok, result} = Availability.get(@date, price.id, @now)
    assert List.last(result.available_times) == "15:00"
    assert {:ok, _} = Catalog.update_service_price(price, %{duration_minutes: 600})
    assert {:ok, %{available_times: []}} = Availability.get(@date, price.id, @now)
  end

  for status <- [:pending, :confirmed] do
    test "#{status} appointments block duration and buffer on both sides", %{price: price} do
      {opens, _} = Availability.business_hours(@date)
      insert_booking(price, DateTime.add(opens, 120 * 60, :second), unquote(status))
      assert {:ok, result} = Availability.get(@date, price.id, @now)
      # Existing 11:00-12:30 + buffer through 13:00.
      # Requested 09:30 also overlaps because its own buffer ends at 11:30.
      assert "09:00" in result.available_times

      for time <- ["09:30", "10:00", "10:30", "11:00", "11:30", "12:00", "12:30"] do
        refute time in result.available_times
      end

      assert "13:00" in result.available_times
    end
  end

  for status <- [:cancelled, :completed] do
    test "#{status} appointments do not block future availability", %{price: price} do
      {opens, _} = Availability.business_hours(@date)
      insert_booking(price, opens, unquote(status))
      assert {:ok, result} = Availability.get(@date, price.id, @now)
      assert "09:00" in result.available_times
    end
  end

  test "same-day slots must be strictly later than now in Denver", %{price: price} do
    assert {:ok, result} = Availability.get("2026-10-19", price.id, ~U[2026-10-19 15:30:00Z])
    refute "09:00" in result.available_times
    refute "09:30" in result.available_times
    assert hd(result.available_times) == "10:00"

    assert {:ok, %{available_times: []}} =
             Availability.get("2026-10-19", price.id, ~U[2026-10-20 00:00:00Z])
  end

  test "Denver calendar date and UTC business hours follow DST", %{price: price} do
    assert Availability.business_hours(~D[2026-10-20]) ==
             {~U[2026-10-20 15:00:00Z], ~U[2026-10-21 00:00:00Z]}

    assert Availability.business_hours(~D[2026-11-02]) ==
             {~U[2026-11-02 16:00:00Z], ~U[2026-11-03 01:00:00Z]}

    assert Availability.business_hours(~D[2027-03-15]) ==
             {~U[2027-03-15 15:00:00Z], ~U[2027-03-16 00:00:00Z]}

    # UTC has rolled to Tuesday, but it is still Monday evening in Denver.
    assert {:ok, %{available_times: []}} =
             Availability.get("2026-10-19", price.id, ~U[2026-10-20 02:00:00Z])
  end

  test "existing overnight occupied periods are considered", %{price: price} do
    {opens, _} = Availability.business_hours(@date)
    attrs = booking_attrs(price, @date)

    %Appointment{
      business_id: price.business_id,
      shop_id: price.shop_id,
      price_cents: price.price_cents,
      duration_minutes: 180
    }
    |> Appointment.changeset(%{attrs | starts_at: DateTime.add(opens, -120 * 60, :second)})
    |> Repo.insert!()

    assert {:ok, result} = Availability.get(@date, price.id, @now)
    refute "09:00" in result.available_times
    assert "10:30" in result.available_times
  end

  test "creation rechecks availability and keeps catalog snapshots", %{price: price} do
    attrs = booking_attrs(price)

    assert {:ok, appointment} =
             Appointments.create_appointment(
               Map.merge(attrs, %{status: "cancelled", price_cents: 1, duration_minutes: 1})
             )

    assert appointment.status == :pending
    assert appointment.price_cents == price.price_cents
    assert appointment.duration_minutes == 90
    assert {:error, changeset} = Appointments.create_appointment(attrs)
    assert errors_on(changeset).starts_at

    assert {:error, changeset} =
             Appointments.create_appointment(%{
               attrs
               | starts_at: DateTime.add(attrs.starts_at, 90 * 60, :second)
             })

    assert errors_on(changeset).starts_at
    # Touching the end of the buffer is permitted.
    assert {:ok, _} =
             Appointments.create_appointment(%{
               attrs
               | starts_at: DateTime.add(attrs.starts_at, 120 * 60, :second)
             })
  end

  test "creation rejects off-grid, past, closed-day, late and out-of-window starts", %{
    price: price
  } do
    attrs = booking_attrs(price)
    {opens, _} = Availability.business_hours(~D[2020-01-01])
    future = Date.add(booking_date(), 91)
    {outside, _} = Availability.business_hours(future)

    sunday =
      Enum.find(
        Date.range(booking_date(), Date.add(booking_date(), 6)),
        &(Date.day_of_week(&1) == 7)
      )

    {closed, _} = Availability.business_hours(sunday)

    for start <- [
          opens,
          outside,
          closed,
          DateTime.add(attrs.starts_at, -30 * 60, :second),
          DateTime.add(attrs.starts_at, 1, :second),
          DateTime.add(attrs.starts_at, 15 * 60, :second),
          DateTime.add(attrs.starts_at, 450 * 60, :second)
        ] do
      assert {:error, changeset} = Appointments.create_appointment(%{attrs | starts_at: start})
      assert errors_on(changeset).starts_at
    end

    # 16:00 + 90 minutes + buffer ends exactly at 18:00.
    assert {:ok, _} =
             Appointments.create_appointment(%{
               attrs
               | starts_at: DateTime.add(attrs.starts_at, 420 * 60, :second)
             })
  end

  test "database rejects overlap even when bypassing availability and different prices are used",
       %{price: price} do
    attrs = booking_attrs(price)
    assert {:ok, _} = Appointments.create_appointment(attrs)
    size = vehicle_size_fixture(%{name: "Other", sort_order: 43})

    {:ok, other_price} =
      Catalog.create_service_price(%{
        service_id: price.service_id,
        vehicle_size_id: size.id,
        duration_minutes: 30,
        price_cents: 100
      })

    changeset =
      Appointment.changeset(
        %Appointment{
          business_id: other_price.business_id,
          shop_id: other_price.shop_id,
          price_cents: other_price.price_cents,
          duration_minutes: 30
        },
        %{
          attrs
          | service_price_id: other_price.id,
            starts_at: DateTime.add(attrs.starts_at, 60 * 60, :second)
        }
      )

    assert {:error, changeset} = Repo.insert(changeset, mode: :savepoint)
    assert "is no longer available" in errors_on(changeset).starts_at
  end

  defp insert_booking(price, starts_at, status) do
    %Appointment{
      business_id: price.business_id,
      shop_id: price.shop_id,
      price_cents: price.price_cents,
      duration_minutes: price.duration_minutes,
      status: status
    }
    |> Appointment.changeset(%{booking_attrs(price, @date) | starts_at: starts_at})
    |> Repo.insert!()
  end
end
