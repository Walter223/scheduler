defmodule SchedulerApi.AppointmentConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  import SchedulerApi.ShopsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Appointments, Catalog, Repo}
  alias SchedulerApi.Organizations.Shop
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}

  setup do
    # A shared SQL Sandbox connection would serialize the requests artificially.
    # Commit isolated fixtures, then give each worker its own real transaction.
    {price, other_price, other_shop_price} =
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

        {price, other_price, shop_price_fixture(price)}
      end)

    price_ids = [price.id, other_price.id, other_shop_price.price.id]
    size_ids = [price.vehicle_size_id, other_price.vehicle_size_id]

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in Appointment, where: a.service_price_id in ^price_ids)
        Repo.delete_all(from p in ServicePrice, where: p.id in ^price_ids)
        Repo.delete_all(from shop in Shop, where: shop.id == ^other_shop_price.shop.id)
        Repo.delete_all(from s in Service, where: s.id == ^price.service_id)
        Repo.delete_all(from v in VehicleSize, where: v.id in ^size_ids)
      end)
    end)

    %{price: price, other_price: other_price, other_shop_price: other_shop_price}
  end

  test "independent simultaneous transactions cannot double-book overlapping slots", %{
    price: price
  } do
    assert_bookings([price, price], 1, [0, 30])
  end

  test "different service prices serialize on the same shared resource", %{
    price: price,
    other_price: other_price
  } do
    assert_bookings([price, other_price], 1, [0, 30])
  end

  test "different shops book the exact same start concurrently", %{
    price: price,
    other_shop_price: other
  } do
    assert_bookings([price, other.price], 2, [0, 0])
  end

  test "holding one shop lock does not prevent another shop from completing", %{
    price: price,
    other_shop_price: other
  } do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [-price.shop_id])
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000

    same_shop_worker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:booking_connection, pid})
          Appointments.create_appointment(Repo.get!(Shop, price.shop_id), booking_attrs(price))
        end)
      end)

    try do
      assert_receive {:booking_connection, pid}, 5_000
      assert_waiting_for_shop_lock(pid, System.monotonic_time(:millisecond) + 5_000)

      worker =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            # Independent connection must commit before the first lock is released.
            Appointments.create_appointment(other.shop, booking_attrs(other.price))
          end)
        end)

      assert {:ok, %Appointment{shop_id: shop_id}} = Task.await(worker, 5_000)
      assert shop_id == other.shop.id
      refute Task.yield(same_shop_worker, 0)
    after
      send(holder.pid, :release)
      Task.await(holder, 5_000)
      assert {:ok, %Appointment{}} = Task.await(same_shop_worker, 5_000)
    end
  end

  defp assert_waiting_for_shop_lock(pid, deadline) do
    waiting =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[waiting]]} =
          Repo.query!(
            "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND locktype = 'advisory' AND NOT granted)",
            [pid]
          )

        waiting
      end)

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "same-shop booking did not wait for its scheduling lock"

      assert_waiting_for_shop_lock(pid, deadline)
    end
  end

  defp assert_bookings(prices, successes, offsets) do
    first_date = Sandbox.unboxed_run(Repo, fn -> booking_date() end)

    dates =
      Date.range(first_date, Date.add(first_date, 14))
      |> Enum.reject(&(Date.day_of_week(&1) == 7))
      |> Enum.take(5)

    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    for {date, iteration} <- Enum.with_index(dates, 1) do
      attrs = Sandbox.unboxed_run(Repo, fn -> booking_attrs(hd(prices), date) end)

      tasks =
        for {price, offset} <- Enum.zip(prices, offsets) do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              shop = Repo.get!(Shop, price.shop_id)
              send(parent, {:ready, self()})

              receive do
                :book ->
                  Appointments.create_appointment(shop, %{
                    attrs
                    | service_price_id: price.id,
                      starts_at: DateTime.add(attrs.starts_at, offset * 60)
                  })
              end
            end)
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      for task <- tasks, do: send(task.pid, :book)
      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.count(results, &match?({:ok, %Appointment{}}, &1)) == successes
      failures = Enum.filter(results, &match?({:error, _}, &1))

      if successes == 1 do
        assert [{:error, changeset}] = failures

        assert {"is not an available start time", []} =
                 Keyword.fetch!(changeset.errors, :starts_at)
      else
        assert failures == []
      end

      price_ids = Enum.map(prices, & &1.id)

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(
                 from(a in Appointment, where: a.service_price_id in ^price_ids),
                 :count
               ) == successes * iteration
      end)
    end
  end
end
