defmodule SchedulerApi.AppointmentConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Appointments, Repo}
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}

  test "independent simultaneous transactions cannot double-book overlapping slots" do
    # A shared SQL Sandbox connection would serialize the requests artificially.
    # Commit isolated fixtures, then give each worker its own real transaction.
    price = Sandbox.unboxed_run(Repo, fn -> service_price_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Appointment, where: a.service_price_id == ^price.id)
        Repo.delete_all(from p in ServicePrice, where: p.id == ^price.id)
        Repo.delete_all(from s in Service, where: s.id == ^price.service_id)
        Repo.delete_all(from v in VehicleSize, where: v.id == ^price.vehicle_size_id)
      end)
    end)

    attrs = Sandbox.unboxed_run(Repo, fn -> booking_attrs(price) end)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for offset <- [0, 30] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :book ->
                Appointments.create_appointment(%{
                  attrs
                  | starts_at: DateTime.add(attrs.starts_at, offset * 60, :second)
                })
            end
          end)
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    for task <- tasks, do: send(task.pid, :book)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, %Appointment{}}, &1)) == 1
    assert [{:error, changeset}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Keyword.has_key?(changeset.errors, :starts_at)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(a in Appointment, where: a.service_price_id == ^price.id),
               :count
             ) == 1
    end)
  end
end
