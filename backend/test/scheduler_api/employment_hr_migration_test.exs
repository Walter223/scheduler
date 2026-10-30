defmodule SchedulerApi.EmploymentHRMigrationTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.CompensationFixtures
  import SchedulerApi.EmploymentFixtures
  alias SchedulerApi.Employment.Compensation
  @migration SchedulerApi.Repo.Migrations.AddEmploymentHrAdministration
  @tables ~w(businesses shops users business_memberships role_assignments employments employment_shop_assignments services vehicle_sizes service_prices appointments work_shifts work_shift_audit_events appointment_assignments appointment_assignment_audit_events compensation_rates compensation_audit_events)

  test "populated migration preserves operational/pay rows, records observed classification and round-trips safely" do
    c = compensation_fixture()
    manager = employment_fixture(%{classification: :business_owner}, business: c.business)

    {:ok, _} =
      Compensation.set_rate(
        c.credential,
        c.employment,
        %{amount: "20.00", pay_basis: :hourly, effective_from: ~D[2026-10-30]},
        now: ~U[2026-10-30 18:00:00Z]
      )

    unless Code.ensure_loaded?(@migration),
      do:
        Code.require_file(
          Path.expand(
            "../../priv/repo/migrations/20261030210651_add_employment_hr_administration.exs",
            __DIR__
          )
        )

    schema = "hr_preserve_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    for table <- @tables do
      Repo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
      Repo.query!("INSERT INTO #{schema}.#{table} SELECT * FROM public.#{table}")
    end

    Repo.query!("SET LOCAL search_path TO #{schema}, public")

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

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM employment_classification_history WHERE source='baseline'"
             )

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM employment_hr_audit_events")
    run(:down, :backward)
    assert snapshot() == before

    assert {:error, %Postgrex.Error{postgres: %{constraint: "employments_immutable"}}} =
             Repo.query(
               "UPDATE employments SET classification='detailer' WHERE id=$1",
               [manager.id],
               mode: :savepoint
             )

    run(:up, :forward)
    assert snapshot() == before

    assert {:ok, _} =
             Repo.query("UPDATE employments SET classification='detailer' WHERE id=$1", [
               manager.id
             ])

    assert %{rows: [["business_owner", "detailer"]]} =
             Repo.query!(
               "SELECT previous_classification,classification FROM employment_classification_history WHERE source='changed'"
             )
  end

  defp snapshot,
    do:
      Map.new(@tables, fn table ->
        {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
      end)

  defp run(operation, direction),
    do:
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_030_210_651,
        @migration,
        :forward,
        operation,
        direction,
        log: false
      )
end
