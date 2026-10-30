# This script is only run by Playwright, never by the production application.
unless Mix.env() == :test and
         Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)[:database] ==
           "scheduler_api_test_e2e" do
  raise "E2E helpers require MIX_ENV=test and MIX_TEST_PARTITION=_e2e"
end

[command | args] = System.argv()
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

  def cleanup(run_id) do
    sequence_info!(run_id)
    shop = Organizations.default_shop!()

    Repo.transaction(fn ->
      services =
        from s in Service,
          where:
            s.business_id == ^shop.business_id and s.name in @service_names and
              like(s.description, ^"#{@marker}#{run_id}: %"),
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

      Repo.query!("DROP SEQUENCE #{sequence(run_id)}")
    end)
  end

  def seed(run_id) do
    sequence(run_id)

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
            Catalog.update_service(service, %{
              description: @marker <> run_id <> ": " <> service.description
            })
        end

        date = booking_date()
        # First Monday on/after tomorrow; base dates use alternating weeks.
        base = Date.add(date, rem(8 - Date.day_of_week(date), 7))
        info = Jason.encode!(%{owner: run_id, base: Date.to_iso8601(base)})
        Repo.query!("CREATE SEQUENCE #{sequence(run_id)}")
        Repo.query!("COMMENT ON SEQUENCE #{sequence(run_id)} IS '#{info}'")

        %{
          services:
            SchedulerApiWeb.ServiceJSON.index(%{services: Catalog.list_services_with_prices()})
        }
      end)

    IO.puts("MAGNUM_E2E_JSON:" <> Jason.encode!(result))
  end

  def allocate(run_id) do
    info = sequence_info!(run_id)
    %{rows: [[index]]} = Repo.query!("SELECT nextval('#{sequence(run_id)}')")
    slot(run_id, index, info)
  end

  def cleanup_slot(run_id, index) do
    info = sequence_info!(run_id)
    data = slot(run_id, index, info)
    date = Date.from_iso8601!(data.date)
    {opens, closes} = Availability.business_hours(date)
    shop = Organizations.default_shop!()

    prices =
      from p in ServicePrice,
        join: s in Service,
        on: s.id == p.service_id,
        where:
          p.shop_id == ^shop.id and s.business_id == ^shop.business_id and
            like(s.description, ^"#{@marker}#{run_id}: %"),
        select: p.id

    Repo.delete_all(
      from a in Appointment,
        where:
          a.service_price_id in subquery(prices) and
            a.starts_at >= ^opens and a.starts_at < ^closes
    )
  end

  defp slot(_run_id, index, info) when index in 1..36 do
    offset = index - 1
    date = Date.from_iso8601!(info["base"]) |> Date.add(div(offset, 6) * 14 + rem(offset, 6))
    {opens, _} = Availability.business_hours(date)
    %{slot_id: index, date: Date.to_iso8601(date), starts_at: DateTime.to_iso8601(opens)}
  end

  defp slot(_, _, _),
    do: raise("E2E date reservation capacity exceeded; expand allocation deliberately")

  defp sequence(run_id) do
    unless Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
             run_id
           ),
           do: raise("Invalid E2E owner ID")

    "magnum_e2e_" <> String.replace(run_id, "-", "")
  end

  defp sequence_info!(run_id) do
    name = sequence(run_id)

    %{rows: [[comment]]} =
      Repo.query!(
        "SELECT obj_description(c.oid, 'pg_class') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='S' AND c.relname=$1 AND n.nspname=current_schema()",
        [name]
      )

    info = Jason.decode!(comment)

    unless info["owner"] == run_id,
      do: raise("Sequence ownership mismatch; refusing fixture operation")

    info
  end
end

case {command, args} do
  {"server", []} ->
    receive do
      :stop -> :ok
    end

  {"seed", [run_id]} ->
    SchedulerApi.E2EFixtures.seed(run_id)

  {"allocate", [run_id]} ->
    IO.puts("MAGNUM_E2E_JSON:" <> Jason.encode!(SchedulerApi.E2EFixtures.allocate(run_id)))

  {"cleanup-slot", [run_id, index]} ->
    SchedulerApi.E2EFixtures.cleanup_slot(run_id, String.to_integer(index))

  {"cleanup", [run_id]} ->
    SchedulerApi.E2EFixtures.cleanup(run_id)
end
