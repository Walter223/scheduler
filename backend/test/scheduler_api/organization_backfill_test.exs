defmodule SchedulerApi.OrganizationBackfillTest do
  use SchedulerApi.DataCase, async: false

  @migration SchedulerApi.Repo.Migrations.EstablishMagnumTenantOwnership
  @tables ~w(services vehicle_sizes service_prices appointments)

  test "migration preserves every legacy row and creates exactly one known business/shop" do
    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20261027023327_establish_magnum_tenant_ownership.exs",
          __DIR__
        )
      )
    end

    # All DDL/data live in this test transaction and an isolated schema. No
    # production/test-public migrations are rolled back and no rows are deleted.
    schema = "ownership_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")
    for sql <- legacy_tables(), do: Repo.query!(sql)
    seed_legacy_rows()
    before = snapshot()
    exclusion = exclusion_definition()

    for sql <- apply(@migration, :statements, []), do: Repo.query!(sql)

    assert snapshot() == before
    assert Enum.map(@tables, &length(before[&1])) == [1, 2, 2, 4]

    assert %{rows: [[business_id, "Magnum Detailing", "magnum-detailing", "active"]]} =
             Repo.query!("SELECT id, name, slug, status FROM businesses")

    assert %{
             rows: [
               [
                 shop_id,
                 ^business_id,
                 "Magnum Detailing Default Location",
                 "default",
                 "America/Denver",
                 "active"
               ]
             ]
           } =
             Repo.query!("SELECT id, business_id, name, slug, timezone, status FROM shops")

    for table <- @tables do
      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM #{table} WHERE business_id IS DISTINCT FROM $1",
                 [business_id]
               )
    end

    for table <- ~w(service_prices appointments) do
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM #{table} WHERE shop_id IS DISTINCT FROM $1", [
                 shop_id
               ])
    end

    assert exclusion_definition() == exclusion
  end

  defp snapshot do
    Map.new(@tables, fn table ->
      {table,
       Repo.query!(
         "SELECT id, to_jsonb(t) - 'business_id' - 'shop_id' FROM #{table} t ORDER BY id"
       ).rows}
    end)
  end

  defp exclusion_definition do
    Repo.query!(
      "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'appointments'::regclass AND conname = 'appointments_no_active_overlap'"
    ).rows
  end

  defp legacy_tables do
    [
      "CREATE TABLE services (id bigint PRIMARY KEY, name varchar(255) NOT NULL, description text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL)",
      "CREATE UNIQUE INDEX services_name_index ON services(name)",
      "CREATE TABLE vehicle_sizes (id bigint PRIMARY KEY, name varchar(255) NOT NULL, sort_order integer NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL)",
      "CREATE UNIQUE INDEX vehicle_sizes_name_index ON vehicle_sizes(name)",
      "CREATE UNIQUE INDEX vehicle_sizes_sort_order_index ON vehicle_sizes(sort_order)",
      "CREATE TABLE service_prices (id bigint PRIMARY KEY, service_id bigint NOT NULL REFERENCES services(id), vehicle_size_id bigint NOT NULL REFERENCES vehicle_sizes(id), price_cents integer NOT NULL, duration_minutes integer NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL)",
      "CREATE UNIQUE INDEX service_prices_service_id_vehicle_size_id_index ON service_prices(service_id, vehicle_size_id)",
      "CREATE TABLE appointments (id bigint PRIMARY KEY, service_price_id bigint NOT NULL REFERENCES service_prices(id), starts_at timestamp(0) NOT NULL, price_cents integer NOT NULL, duration_minutes integer NOT NULL, customer_first_name varchar(100) NOT NULL, customer_last_name varchar(100) NOT NULL, customer_email varchar(255) NOT NULL, customer_phone varchar(255) NOT NULL, vehicle_make varchar(255) NOT NULL, vehicle_model varchar(255) NOT NULL, notes text, status varchar(255) NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL)",
      "ALTER TABLE appointments ADD CONSTRAINT appointments_no_active_overlap EXCLUDE USING gist (tsrange(starts_at, starts_at + duration_minutes * interval '1 minute' + interval '30 minutes', '[)') WITH &&) WHERE (status IN ('pending', 'confirmed'))"
    ]
  end

  defp seed_legacy_rows do
    Repo.query!(
      "INSERT INTO services VALUES (81, 'Legacy Detail', 'Original description', '2020-01-01', '2020-02-01')"
    )

    Repo.query!(
      "INSERT INTO vehicle_sizes VALUES (91, 'Small', 1, '2020-01-01', '2020-02-01'), (92, 'Large', 2, '2020-01-01', '2020-02-01')"
    )

    Repo.query!(
      "INSERT INTO service_prices VALUES (101, 81, 91, 8999, 90, '2020-01-01', '2020-02-01'), (102, 81, 92, 14999, 150, '2020-01-01', '2020-02-01')"
    )

    for {status, index} <- Enum.with_index(~w(pending confirmed completed cancelled), 1) do
      Repo.query!(
        """
        INSERT INTO appointments VALUES ($1, 101, $2, 7999, 75, 'Alex Jane', 'van Driver',
        'legacy@example.com', '+13035550100', 'Toyota', 'Camry', $3, $4, '2020-01-01', '2020-02-01')
        """,
        [
          200 + index,
          ~N[2020-06-01 15:00:00] |> NaiveDateTime.add(index * 86_400),
          "Original notes #{index}\n第二行",
          status
        ]
      )
    end
  end
end
