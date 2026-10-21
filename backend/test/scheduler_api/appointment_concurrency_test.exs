defmodule SchedulerApi.AppointmentConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Appointments, Catalog, Repo}
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}

  setup do
    # A shared SQL Sandbox connection would serialize the requests artificially.
    # Commit isolated fixtures, then give each worker its own real transaction.
    {price, other_price} =
      Sandbox.unboxed_run(Repo, fn ->
        price = service_price_fixture()
        size = vehicle_size_fixture(%{name: "Other size", sort_order: 43})

        {:ok, other_price} =
          Catalog.create_service_price(%{
            service_id: price.service_id,
            vehicle_size_id: size.id,
            price_cents: 100,
            duration_minutes: 90
          })

        {price, other_price}
      end)

    price_ids = [price.id, other_price.id]
    size_ids = [price.vehicle_size_id, other_price.vehicle_size_id]

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Appointment, where: a.service_price_id in ^price_ids)
        Repo.delete_all(from p in ServicePrice, where: p.id in ^price_ids)
        Repo.delete_all(from s in Service, where: s.id == ^price.service_id)
        Repo.delete_all(from v in VehicleSize, where: v.id in ^size_ids)
      end)
    end)

    %{price: price, other_price: other_price}
  end

  test "independent simultaneous transactions cannot double-book overlapping slots", %{
    price: price
  } do
    assert_single_booking([price, price])
  end

  test "different service prices serialize on the same shared resource", %{
    price: price,
    other_price: other_price
  } do
    assert_single_booking([price, other_price])
  end

  defp assert_single_booking(prices) do
    attrs = Sandbox.unboxed_run(Repo, fn -> booking_attrs(hd(prices)) end)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for {price, offset} <- Enum.zip(prices, [0, 30]) do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :book ->
                Appointments.create_appointment(%{
                  attrs
                  | service_price_id: price.id,
                    starts_at: DateTime.add(attrs.starts_at, offset * 60, :second)
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
    assert {"is not an available start time", []} = Keyword.fetch!(changeset.errors, :starts_at)

    price_ids = Enum.map(prices, & &1.id)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(a in Appointment, where: a.service_price_id in ^price_ids),
               :count
             ) == 1
    end)
  end
end
