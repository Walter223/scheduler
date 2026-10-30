defmodule SchedulerApi.RehireMigrationTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.CompensationFixtures
  alias SchedulerApi.Employment
  @migration SchedulerApi.Repo.Migrations.AddEmploymentPeriodsAndRehire
  @tables ~w(businesses shops users business_memberships role_assignments employments employment_shop_assignments services vehicle_sizes service_prices appointments work_shifts work_shift_audit_events appointment_assignments appointment_assignment_audit_events compensation_rates compensation_audit_events employment_classification_history employment_hr_audit_events employment_offboarding_audits)
  test "populated legacy migration preserves rows, IDs and history while backfilling stable identity" do
    c = compensation_fixture()
    {:ok, _} = Employment.end_employment(c.employment, ~D[2026-02-01])

    unless Code.ensure_loaded?(@migration),
      do:
        Code.require_file(
          Path.expand(
            "../../priv/repo/migrations/20261030220303_add_employment_periods_and_rehire.exs",
            __DIR__
          )
        )

    schema = "rehire_preserve_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    for table <- @tables do
      Repo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
      Repo.query!("INSERT INTO #{schema}.#{table} SELECT * FROM public.#{table}")
    end

    Repo.query!("SET LOCAL search_path TO #{schema},public")
    Repo.query!("ALTER TABLE employments DROP COLUMN employee_id CASCADE")

    Repo.query!(
      "CREATE UNIQUE INDEX employments_business_id_user_id_index ON employments(business_id,user_id) WHERE user_id IS NOT NULL"
    )

    original =
      File.read!(
        Path.expand(
          "../../priv/repo/migrations/20261030011705_create_employment_records.exs",
          __DIR__
        )
      )

    [guard] = Regex.run(~r/CREATE FUNCTION magnum_guard_employment\(\).*?END \$\$/s, original)
    Repo.query!(guard)

    Repo.query!(
      "CREATE TRIGGER employment_guard BEFORE INSERT OR UPDATE ON employments FOR EACH ROW EXECUTE FUNCTION magnum_guard_employment()"
    )

    before = snapshot()
    run(:up, :forward)
    assert snapshot() == before
    assert %{rows: [[true]]} = Repo.query!("SELECT bool_and(employee_id=id) FROM employments")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM employment_rehire_audits")
    run(:down, :backward)
    assert snapshot() == before
    run(:up, :forward)
    assert snapshot() == before
  end

  defp snapshot,
    do:
      Map.new(@tables, fn table ->
        {table, Repo.query!("SELECT to_jsonb(t)-'employee_id' FROM #{table} t ORDER BY id").rows}
      end)

  defp run(operation, direction),
    do:
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_030_220_303,
        @migration,
        :forward,
        operation,
        direction,
        log: false
      )
end
