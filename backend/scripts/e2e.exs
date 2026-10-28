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
  alias SchedulerApi.{Catalog, Organizations, Repo}
  alias SchedulerApi.Appointments.{Appointment, Availability}
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}
  import SchedulerApi.AppointmentsFixtures

  @service_names ["Basic Detail", "Mid Detail", "Supreme Detail"]
  @size_names ["Small", "Medium", "Large"]
  @marker "Playwright-owned fixture: "

  def cleanup do
    shop = Organizations.default_shop!()

    Repo.transaction(fn ->
      services =
        from s in Service,
          where:
            s.business_id == ^shop.business_id and s.name in @service_names and
              like(s.description, ^"#{@marker}%"),
          select: s.id

      service_ids = Repo.all(services)
      prices = from p in ServicePrice, where: p.service_id in ^service_ids, select: p.id

      size_ids =
        Repo.all(
          from p in ServicePrice,
            where: p.service_id in ^service_ids,
            distinct: true,
            select: p.vehicle_size_id
        )

      # Never remove someone else's prices or shared sizes, even in the test DB.
      if Repo.exists?(
           from p in ServicePrice,
             where:
               (p.service_id in ^service_ids and p.shop_id != ^shop.id) or
                 (p.vehicle_size_id in ^size_ids and p.service_id not in ^service_ids)
         ) do
        raise "E2E catalog has foreign references; refusing cleanup"
      end

      Repo.delete_all(from a in Appointment, where: a.service_price_id in subquery(prices))
      Repo.delete_all(from p in ServicePrice, where: p.id in subquery(prices))
      Repo.delete_all(from s in Service, where: s.id in ^service_ids)

      Repo.delete_all(
        from v in VehicleSize, where: v.id in ^size_ids and v.business_id == ^shop.business_id
      )
    end)
  end

  def seed do
    cleanup()

    {:ok, result} =
      Repo.transaction(fn ->
        shop = Organizations.default_shop!()

        if Repo.exists?(
             from s in Service,
               where: s.business_id == ^shop.business_id and s.name in @service_names
           ) or
             Repo.exists?(
               from v in VehicleSize,
                 where: v.business_id == ^shop.business_id and v.name in @size_names
             ) do
          raise "E2E catalog names already exist without fixture ownership; refusing to overwrite"
        end

        # Exercise the actual source-controlled catalog, not one synthetic offering.
        Code.eval_file(Path.expand("../priv/repo/seeds.exs", __DIR__))

        for service <- Catalog.list_services_with_prices(), service.name in @service_names do
          {:ok, _} =
            Catalog.update_service(service, %{description: @marker <> service.description})
        end

        date = booking_date()
        {opens, _} = Availability.business_hours(date)

        %{
          date: Date.to_iso8601(date),
          starts_at: DateTime.to_iso8601(opens),
          services:
            SchedulerApiWeb.ServiceJSON.index(%{services: Catalog.list_services_with_prices()})
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
