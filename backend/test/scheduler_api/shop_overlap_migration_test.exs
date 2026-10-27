defmodule SchedulerApi.ShopOverlapMigrationTest do
  use SchedulerApi.DataCase, async: false

  @migration SchedulerApi.Repo.Migrations.ScopeAppointmentOverlapToShop

  test "constraint replacement preserves legacy appointments and allows cross-shop overlap" do
    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20261027025608_scope_appointment_overlap_to_shop.exs",
          __DIR__
        )
      )
    end

    schema = "shop_overlap_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    Repo.query!("""
    CREATE TABLE appointments (
      id bigint PRIMARY KEY, shop_id bigint NOT NULL, starts_at timestamp(0) NOT NULL,
      duration_minutes integer NOT NULL, price_cents integer NOT NULL, status text NOT NULL,
      customer_first_name text NOT NULL, customer_last_name text NOT NULL, notes text,
      inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
    )
    """)

    Repo.query!("""
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_active_overlap EXCLUDE USING gist (
      tsrange(starts_at, starts_at + duration_minutes * interval '1 minute' + interval '30 minutes', '[)') WITH &&
    ) WHERE (status IN ('pending', 'confirmed'))
    """)

    for {status, id} <- Enum.with_index(~w(pending confirmed cancelled completed), 1) do
      Repo.query!(
        "INSERT INTO appointments VALUES ($1, 1, $2, 90, 8999, $3, 'Alex Jane', 'van Driver', 'Original notes 第二行', '2020-01-01', '2020-02-01')",
        [id, NaiveDateTime.add(~N[2020-06-01 15:00:00], id * 86_400), status]
      )
    end

    before = Repo.query!("SELECT to_jsonb(a) FROM appointments a ORDER BY id").rows
    for sql <- apply(@migration, :statements, []), do: Repo.query!(sql)
    assert Repo.query!("SELECT to_jsonb(a) FROM appointments a ORDER BY id").rows == before

    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'appointments'::regclass AND conname = 'appointments_no_active_overlap'"
             )

    assert definition =~ "shop_id WITH ="
    assert definition =~ "'00:30:00'::interval"
    assert definition =~ "pending"
    assert definition =~ "confirmed"

    assert %{num_rows: 1} =
             Repo.query!(
               "INSERT INTO appointments SELECT 99, 2, starts_at, duration_minutes, price_cents, status, customer_first_name, customer_last_name, notes, inserted_at, updated_at FROM appointments WHERE id = 1"
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} =
             Repo.query(
               "INSERT INTO appointments SELECT 100, 1, starts_at, duration_minutes, price_cents, status, customer_first_name, customer_last_name, notes, inserted_at, updated_at FROM appointments WHERE id = 1",
               [],
               mode: :savepoint
             )
  end
end
