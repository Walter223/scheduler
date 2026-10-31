defmodule SchedulerApi.CalendarTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Appointments, Repo}
  alias SchedulerApi.Appointments.{Calendar, JobAssignments, JobAssignment, Appointment}
  setup do: job_fixture()

  defp options(c, extra \\ %{}) do
    date =
      c.booking.starts_at
      |> Appointments.Availability.local_datetime()
      |> NaiveDateTime.to_date()
      |> Date.to_iso8601()

    Map.merge(%{"date" => date, "shop_id" => "#{c.shop.id}"}, extra)
  end

  test "bounded crew counts and minimal vehicle detail are complete, status filters preserve cancellation",
       c do
    {:ok, first} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    second = second_detailer(c)
    {:ok, _} = JobAssignments.add_member(c.credential, c.booking, second.assignment)

    {:ok, _} =
      JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: first.id})

    assert {:ok, %{"appointments" => [row]}} = Calendar.read(c.owner, c.business.id, options(c))
    assert row["crew_size"] == 2 and row["lead_detailer"] == "Taylor Worker"
    assert row["vehicle_make"] == "Toyota"
    refute Map.has_key?(row, "customer_email")

    assert {:ok, %{"appointments" => []}} =
             Calendar.read(c.owner, c.business.id, options(c, %{"status" => "cancelled"}))
  end

  test "All Shops and scoped cursor never borrow another grant's business or shop", c do
    other = shop_price_fixture(c.price)

    {:ok, _} =
      Appointments.create_appointment(
        other.shop,
        SchedulerApi.AppointmentsFixtures.booking_attrs(other.price)
      )

    all = options(c) |> Map.delete("shop_id") |> Map.put("limit", "1")
    assert {:ok, page} = Calendar.read(c.owner, c.business.id, all)
    assert page["meta"].has_more
    cursor = page["meta"].next_cursor
    assert {:ok, second} = Calendar.read(c.owner, c.business.id, Map.put(all, "cursor", cursor))
    refute hd(page["appointments"])["id"] == hd(second["appointments"])["id"]

    assert {:error, :invalid_input} =
             Calendar.read(c.owner, c.business.id, options(c, %{"cursor" => cursor}))

    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    assert {:ok, %{"appointments" => [row]}} = Calendar.read(sm, c.business.id, options(c))
    assert row["id"] == c.booking.id
    assert {:error, :forbidden} = Calendar.read(sm, c.business.id, all)

    assert {:error, :forbidden} =
             Calendar.read(sm, c.business.id, options(c, %{"shop_id" => "#{other.shop.id}"}))

    for role <- [:business_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      assert {:error, :forbidden} = Calendar.read(user, c.business.id, options(c))
    end

    foreign = job_fixture()
    assert {:error, :forbidden} = Calendar.read(c.owner, foreign.business.id, options(foreign))
    grant_fixture(c.owner, foreign.shop, :business_owner)

    assert {:ok, %{"appointments" => [foreign_row]}} =
             Calendar.read(c.owner, foreign.business.id, options(foreign))

    assert foreign_row["id"] == foreign.booking.id
  end

  test "validated bounded windows and filter-bound cursors", c do
    for extra <- [
          %{"days" => "8"},
          %{"limit" => "101"},
          %{"date" => "2026-02-30"},
          %{"status" => "deleted"},
          %{"cursor" => "bad"},
          %{"business_id" => "1"}
        ] do
      assert {:error, :invalid_input} = Calendar.read(c.owner, c.business.id, options(c, extra))
    end

    assert {:ok, _} = Calendar.read(c.owner, c.business.id, options(c, %{"days" => "7"}))
    {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(c.membership)
    assert {:error, :forbidden} = Calendar.read(c.owner, c.business.id, options(c))
  end

  test "local DST day boundaries are half-open and display UTC timestamps", c do
    other = shop_price_fixture(c.price)
    Repo.update!(Ecto.Changeset.change(other.shop, timezone: "America/New_York"))

    attrs =
      c.booking
      |> Map.from_struct()
      |> Map.drop([:id, :__meta__, :business, :shop, :service_price])

    for {date, first, last} <- [
          {"2026-03-08", ~U[2026-03-08 07:00:00Z], ~U[2026-03-09 06:00:00Z]},
          {"2026-11-01", ~U[2026-11-01 06:00:00Z], ~U[2026-11-02 07:00:00Z]}
        ] do
      a = Repo.insert!(struct!(Appointment, %{attrs | starts_at: first, status: :cancelled}))
      b = Repo.insert!(struct!(Appointment, %{attrs | starts_at: last, status: :cancelled}))

      assert {:ok, %{"appointments" => [row]}} =
               Calendar.read(c.owner, c.business.id, options(c, %{"date" => date}))

      assert row["id"] == a.id and row["crew_size"] == 0 and row["status"] == "cancelled"

      east =
        Repo.insert!(
          struct!(Appointment, %{
            attrs
            | starts_at: DateTime.add(first, -3600),
              shop_id: other.shop.id,
              service_price_id: other.price.id,
              status: :cancelled
          })
        )

      all = options(c, %{"date" => date}) |> Map.delete("shop_id")
      assert {:ok, result} = Calendar.read(c.owner, c.business.id, all)

      assert Enum.any?(
               result["appointments"],
               &(&1["id"] == east.id and &1["timezone"] == "America/New_York")
             )

      Repo.delete!(east)
      Repo.delete!(a)
      Repo.delete!(b)
    end
  end
end
