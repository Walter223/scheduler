# This script is only run by Playwright, never by the production application.
unless Mix.env() == :test and
         Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)[:database] ==
           "scheduler_api_test_e2e" do
  raise "E2E helpers require MIX_ENV=test and MIX_TEST_PARTITION=_e2e"
end

[command] = System.argv()
endpoint = SchedulerApiWeb.Endpoint
config = Application.fetch_env!(:scheduler_api, endpoint)

Application.put_env(
  :scheduler_api,
  endpoint,
  Keyword.merge(config, server: command == "server", http: [ip: {127, 0, 0, 1}, port: 4002])
)

{:ok, _} = Application.ensure_all_started(:scheduler_api)
Ecto.Adapters.SQL.Sandbox.mode(SchedulerApi.Repo, :auto)

defmodule SchedulerApi.E2EFixtures do
  import Ecto.Query
  alias SchedulerApi.{Catalog, Repo}
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}
  import SchedulerApi.AppointmentsFixtures

  @service_name "E2E Mid Detail"
  @size_name "E2E Small"

  def cleanup do
    Repo.transaction(fn ->
      prices =
        from p in ServicePrice,
          join: s in Service,
          on: p.service_id == s.id,
          where: s.name == @service_name,
          select: p.id

      Repo.delete_all(from a in Appointment, where: a.service_price_id in subquery(prices))
      Repo.delete_all(from p in ServicePrice, where: p.id in subquery(prices))
      Repo.delete_all(from s in Service, where: s.name == @service_name)
      Repo.delete_all(from v in VehicleSize, where: v.name == @size_name)
    end)
  end

  def seed do
    # Clear only our named fixtures, including leftovers from an interrupted run.
    cleanup()

    {:ok, result} =
      Repo.transaction(fn ->
        {:ok, service} =
          Catalog.create_service(%{
            name: @service_name,
            description: "Playwright booking fixture"
          })

        {:ok, size} = Catalog.create_vehicle_size(%{name: @size_name, sort_order: 10_000})

        {:ok, price} =
          Catalog.create_service_price(%{
            service_id: service.id,
            vehicle_size_id: size.id,
            duration_minutes: 90,
            price_cents: 8999
          })

        date = booking_date()
        attrs = booking_attrs(price, date)

        %{
          service_id: service.id,
          service_price_id: price.id,
          service_name: service.name,
          vehicle_size: size.name,
          date: Date.to_iso8601(date),
          starts_at: DateTime.to_iso8601(attrs.starts_at)
        }
      end)

    IO.puts(Jason.encode!(result))
  end
end

case command do
  "server" ->
    receive do
      :stop -> :ok
    end

  "seed" ->
    SchedulerApi.E2EFixtures.seed()

  "cleanup" ->
    SchedulerApi.E2EFixtures.cleanup()
end
