defmodule SchedulerApi.MembershipMigrationTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  @migration SchedulerApi.Repo.Migrations.AddBusinessMembershipsAndRoleAssignments
  @tables ~w(users businesses shops services vehicle_sizes service_prices appointments web_sessions login_transactions)

  test "up/down preserve existing records and migration gives existing identities no membership or grant" do
    user_fixture()

    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20261029231656_add_business_memberships_and_role_assignments.exs",
          __DIR__
        )
      )
    end

    schema = "rbac_preserve_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    for table <- @tables do
      Repo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
      Repo.query!("INSERT INTO #{schema}.#{table} SELECT * FROM public.#{table}")
    end

    Repo.query!("SET LOCAL search_path TO #{schema}, public")
    before = snapshot()
    run(:up, :forward)
    assert snapshot() == before
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM business_memberships")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM role_assignments")
    run(:down, :backward)
    assert snapshot() == before

    assert %{rows: [[nil, nil]]} =
             Repo.query!("SELECT to_regclass($1), to_regclass($2)", [
               schema <> ".business_memberships",
               schema <> ".role_assignments"
             ])
  end

  defp snapshot do
    Map.new(@tables, fn table ->
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
    end)
  end

  defp run(operation, direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_029_231_656,
      @migration,
      :forward,
      operation,
      direction,
      log: false
    )
  end
end
