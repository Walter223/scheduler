defmodule SchedulerApi.Repo.Migrations.EstablishMagnumTenantOwnership do
  use Ecto.Migration

  def up do
    Enum.each(statements(), &execute/1)
  end

  def down do
    raise Ecto.MigrationError, "Tenant ownership requires a reviewed data-preserving rollback"
  end

  # SQL is kept together so the migration can also be exercised against legacy
  # rows in an isolated test schema, without rolling back the application DB.
  @doc false
  def statements do
    [
      "CREATE TEMP TABLE magnum_ownership_snapshot ON COMMIT DROP AS " <> legacy_rows(false),
      """
      CREATE TABLE businesses (
        id bigserial PRIMARY KEY,
        name varchar(255) NOT NULL CHECK (name ~ '[^[:space:]]'),
        slug varchar(255) NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
        status varchar(255) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      )
      """,
      """
      CREATE TABLE shops (
        id bigserial PRIMARY KEY,
        business_id bigint NOT NULL REFERENCES businesses(id) ON DELETE RESTRICT,
        name varchar(255) NOT NULL CHECK (name ~ '[^[:space:]]'),
        slug varchar(255) NOT NULL CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
        timezone varchar(255) NOT NULL CHECK (timezone ~ '[^[:space:]]'),
        status varchar(255) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        UNIQUE (business_id, slug), UNIQUE (id, business_id)
      )
      """,
      "INSERT INTO businesses (name, slug, inserted_at, updated_at) VALUES ('Magnum Detailing', 'magnum-detailing', timezone('UTC', now()), timezone('UTC', now()))",
      "INSERT INTO shops (business_id, name, slug, timezone, inserted_at, updated_at) SELECT id, 'Magnum Detailing Default Location', 'default', 'America/Denver', timezone('UTC', now()), timezone('UTC', now()) FROM businesses WHERE slug = 'magnum-detailing'"
    ] ++
      Enum.map(["services", "vehicle_sizes", "service_prices", "appointments"], fn table ->
        "ALTER TABLE #{table} ADD COLUMN business_id bigint"
      end) ++
      Enum.map(["service_prices", "appointments"], fn table ->
        "ALTER TABLE #{table} ADD COLUMN shop_id bigint"
      end) ++
      Enum.map(["services", "vehicle_sizes", "service_prices", "appointments"], fn table ->
        "UPDATE #{table} SET business_id = (SELECT id FROM businesses WHERE slug = 'magnum-detailing')"
      end) ++
      Enum.map(["service_prices", "appointments"], fn table ->
        "UPDATE #{table} SET shop_id = (SELECT id FROM shops WHERE slug = 'default')"
      end) ++
      [
        """
        DO $$ BEGIN
          IF EXISTS (
            SELECT 1 FROM magnum_ownership_snapshot original
            FULL JOIN (#{legacy_rows(true)}) current USING (table_name, id)
            WHERE original.row_data IS DISTINCT FROM current.row_data
          ) THEN
            RAISE EXCEPTION 'Tenant backfill changed existing data';
          END IF;
        END $$
        """
      ] ++
      Enum.flat_map(["services", "vehicle_sizes", "service_prices", "appointments"], fn table ->
        [
          "ALTER TABLE #{table} ALTER COLUMN business_id SET NOT NULL",
          "ALTER TABLE #{table} ADD CONSTRAINT #{table}_business_id_fkey FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE RESTRICT",
          "CREATE INDEX #{table}_business_id_index ON #{table} (business_id)"
        ]
      end) ++
      Enum.flat_map(["service_prices", "appointments"], fn table ->
        [
          "ALTER TABLE #{table} ALTER COLUMN shop_id SET NOT NULL",
          "ALTER TABLE #{table} ADD CONSTRAINT #{table}_shop_business_fkey FOREIGN KEY (shop_id, business_id) REFERENCES shops(id, business_id) ON DELETE RESTRICT",
          "CREATE INDEX #{table}_shop_id_index ON #{table} (shop_id)"
        ]
      end) ++
      [
        "CREATE UNIQUE INDEX services_id_business_id_index ON services (id, business_id)",
        "CREATE UNIQUE INDEX vehicle_sizes_id_business_id_index ON vehicle_sizes (id, business_id)",
        "CREATE UNIQUE INDEX service_prices_id_business_shop_index ON service_prices (id, business_id, shop_id)",
        "ALTER TABLE service_prices ADD CONSTRAINT service_prices_service_business_fkey FOREIGN KEY (service_id, business_id) REFERENCES services(id, business_id) ON DELETE RESTRICT",
        "ALTER TABLE service_prices ADD CONSTRAINT service_prices_vehicle_size_business_fkey FOREIGN KEY (vehicle_size_id, business_id) REFERENCES vehicle_sizes(id, business_id) ON DELETE RESTRICT",
        "ALTER TABLE appointments ADD CONSTRAINT appointments_price_ownership_fkey FOREIGN KEY (service_price_id, business_id, shop_id) REFERENCES service_prices(id, business_id, shop_id) ON DELETE RESTRICT",
        "CREATE UNIQUE INDEX services_business_id_name_index ON services (business_id, name)",
        "CREATE UNIQUE INDEX vehicle_sizes_business_id_name_index ON vehicle_sizes (business_id, name)",
        "CREATE UNIQUE INDEX vehicle_sizes_business_id_sort_order_index ON vehicle_sizes (business_id, sort_order)",
        "CREATE UNIQUE INDEX service_prices_shop_service_size_index ON service_prices (shop_id, service_id, vehicle_size_id)",
        "DROP INDEX services_name_index",
        "DROP INDEX vehicle_sizes_name_index",
        "DROP INDEX vehicle_sizes_sort_order_index",
        "DROP INDEX service_prices_service_id_vehicle_size_id_index"
      ]
  end

  defp legacy_rows(strip_ownership) do
    Enum.map_join(
      ["services", "vehicle_sizes", "service_prices", "appointments"],
      " UNION ALL ",
      fn table ->
        data =
          if strip_ownership, do: "to_jsonb(t) - 'business_id' - 'shop_id'", else: "to_jsonb(t)"

        "SELECT '#{table}'::text AS table_name, id, #{data} AS row_data FROM #{table} t"
      end
    )
  end
end
