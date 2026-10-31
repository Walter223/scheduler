defmodule SchedulerApi.DashboardTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.ShopsFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  alias SchedulerApi.{Repo, Employment}
  alias SchedulerApi.Appointments.{Dashboard, Appointment, JobAssignments, JobAssignment}
  alias SchedulerApi.Employment.{WorkSchedules, WorkShift}
  setup do: job_fixture()

  defp read(c, user \\ nil, shop \\ :selected),
    do:
      Dashboard.read(
        user || c.owner,
        c.business.id,
        if(shop == :selected, do: c.shop.id, else: shop),
        c.booking.starts_at
      )

  test "complete totals, team size and lead without customer or private HR data", c do
    {:ok, first} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    second = second_detailer(c)
    {:ok, _} = JobAssignments.add_member(c.credential, c.booking, second.assignment)

    {:ok, _} =
      JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: first.id})

    assert {:ok, data} = read(c)

    assert data["metrics"] == %{
             "appointments" => 1,
             "unassigned" => 0,
             "detailers" => 2,
             "shifts" => 2
           }

    assert [%{"crew_size" => 2, "lead_detailer" => "Taylor Worker"} = item] = data["appointments"]
    refute Map.has_key?(item, "customer_email")
    refute Map.has_key?(item, "price_cents")
  end

  test "pending unassigned counts, cancellation and completion remain distinct", c do
    assert {:ok, %{"metrics" => %{"unassigned" => 1}}} = read(c)
    Repo.update!(Ecto.Changeset.change(c.booking, status: :cancelled))

    assert {:ok,
            %{"metrics" => %{"appointments" => 0, "unassigned" => 0}, "appointments" => [item]}} =
             read(c)

    assert item["status"] == "cancelled"
    Repo.update!(Ecto.Changeset.change(Repo.reload!(c.booking), status: :completed))
    assert {:ok, %{"metrics" => %{"appointments" => 1, "unassigned" => 0}}} = read(c)
  end

  test "All Shops requires a business grant; shop managers and other tenants cannot borrow scope",
       c do
    other = shop_price_fixture(c.price)
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :shop_manager)

    {:ok, _} =
      SchedulerApi.Appointments.create_appointment(
        other.shop,
        SchedulerApi.AppointmentsFixtures.booking_attrs(other.price)
      )

    assert {:ok, %{"metrics" => %{"appointments" => 1, "unassigned" => 1}}} = read(c, manager)
    assert {:ok, %{"metrics" => %{"appointments" => 2, "unassigned" => 2}}} = read(c, nil, nil)
    assert {:error, :forbidden} = read(c, manager, nil)
    assert {:error, :forbidden} = read(c, manager, other.shop.id)

    for role <- [:business_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      assert {:error, :forbidden} = read(c, user)
    end

    foreign = job_fixture()
    grant_fixture(c.owner, foreign.shop, :business_manager)
    assert {:error, :forbidden} = Dashboard.read(c.owner, foreign.business.id, foreign.shop.id)
    grant_fixture(c.owner, foreign.shop, :business_owner)

    assert {:ok, %{"metrics" => %{"appointments" => 1}}} =
             Dashboard.read(c.owner, foreign.business.id, nil, foreign.booking.starts_at)

    assert {:ok, %{"shops" => shops}} = read(c, nil, nil)
    assert length(shops) == 2
  end

  test "multiple shop shifts count the same stable Detailer once", c do
    other = shop_price_fixture(c.price)

    {:ok, assignment} =
      Employment.assign_shop(c.employment, other.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, _} =
      WorkSchedules.create_shift(c.credential, assignment, %{
        starts_at: c.shift.ends_at,
        ends_at: DateTime.add(c.shift.ends_at, 1800)
      })

    assert {:ok, %{"metrics" => %{"shifts" => 2, "detailers" => 1}}} = read(c, nil, nil)
    assert {:ok, %{"metrics" => %{"shifts" => 1}}} = read(c)
  end

  test "Denver UTC crossover, DST spring and fall use midnight-to-next-midnight half-open ranges",
       c do
    other = shop_price_fixture(c.price)
    Repo.update!(Ecto.Changeset.change(other.shop, timezone: "America/New_York"))

    for {date, first, last} <- [
          {"2026-03-08", ~U[2026-03-08 07:00:00Z], ~U[2026-03-09 06:00:00Z]},
          {"2026-11-01", ~U[2026-11-01 06:00:00Z], ~U[2026-11-02 07:00:00Z]}
        ] do
      booking =
        c.booking
        |> Map.from_struct()
        |> Map.drop([:id, :__meta__, :business, :shop, :service_price])

      item = Repo.insert!(struct!(Appointment, %{booking | starts_at: first}))
      # A shift ending at midnight is excluded; one crossing midnight is included.
      shift =
        Repo.get!(WorkShift, c.shift.id)
        |> Map.from_struct()
        |> Map.drop([:id, :__meta__, :assignment, :employment, :business, :shop, :supersedes])

      a =
        Repo.insert!(
          struct!(WorkShift, %{shift | starts_at: DateTime.add(first, -3600), ends_at: first})
        )

      b =
        Repo.insert!(
          struct!(WorkShift, %{
            shift
            | starts_at: DateTime.add(last, -1800),
              ends_at: DateTime.add(last, 1800)
          })
        )

      assert {:ok, data} =
               Dashboard.read(c.owner, c.business.id, c.shop.id, DateTime.add(last, -1))

      assert hd(data["shops"])["date"] == date
      assert {:ok, all} = Dashboard.read(c.owner, c.business.id, nil, DateTime.add(last, -1))
      east = Enum.find(all["shops"], &(&1["id"] == other.shop.id))
      assert east["date"] == date |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()

      assert Enum.map(data["appointments"], & &1["id"]) == [item.id]
      assert data["metrics"]["shifts"] == 1
      Repo.delete!(a)
      Repo.delete!(b)
      Repo.delete!(item)
    end
  end
end
