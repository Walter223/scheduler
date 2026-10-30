defmodule SchedulerApi.AppointmentTeamMigrationTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.Appointments.JobAssignments
  @previous SchedulerApi.Repo.Migrations.CreateEmployeeAppointmentAssignments
  @migration SchedulerApi.Repo.Migrations.SupportAppointmentDetailerTeams
  @tables ~w(businesses shops users business_memberships role_assignments employments employment_shop_assignments services vehicle_sizes service_prices appointments work_shifts work_shift_audit_events)

  test "up/down preserve populated legacy assignments, audit IDs and operational rows without inferring leads" do
    c = job_fixture()
    {:ok, _} = JobAssignments.assign(c.credential, c.booking, c.assignment)

    for {module, file} <- [
          {@previous, "20261030070228_create_employee_appointment_assignments.exs"},
          {@migration, "20261030203830_support_appointment_detailer_teams.exs"}
        ] do
      unless Code.ensure_loaded?(module),
        do: Code.require_file(Path.expand("../../priv/repo/migrations/" <> file, __DIR__))
    end

    schema = "team_preserve_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")

    for table <- @tables do
      Repo.query!("CREATE TABLE #{schema}.#{table} (LIKE public.#{table} INCLUDING ALL)")
      Repo.query!("INSERT INTO #{schema}.#{table} SELECT * FROM public.#{table}")
    end

    Repo.query!("SET LOCAL search_path TO #{schema}, public")
    run(@previous, :up, :forward)

    Repo.query!(
      "INSERT INTO appointment_assignments SELECT id,appointment_id,assignment_id,employment_id,business_id,shop_id,work_shift_id,starts_at,ends_at,status,closed_at,inserted_at FROM public.appointment_assignments"
    )

    Repo.query!(
      "INSERT INTO appointment_assignment_audit_events SELECT id,actor_user_id,appointment_id,business_id,shop_id,job_id,replacement_job_id,action,outcome,reason,occurred_at FROM public.appointment_assignment_audit_events"
    )

    before = snapshot()
    run(@migration, :up, :forward)
    assert snapshot() == before

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM appointment_assignments WHERE is_lead")

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM appointment_assignment_audit_events WHERE previous_lead_job_id IS NOT NULL OR lead_job_id IS NOT NULL"
             )

    run(@migration, :down, :backward)
    assert snapshot() == before
    run(@migration, :up, :forward)
    assert snapshot() == before
  end

  defp snapshot do
    Map.new(
      @tables ++ ~w(appointment_assignments appointment_assignment_audit_events),
      fn table ->
        {table,
         Repo.query!(
           "SELECT to_jsonb(t)-'is_lead'-'previous_lead_job_id'-'lead_job_id' FROM #{table} t ORDER BY id"
         ).rows}
      end
    )
  end

  defp run(module, operation, direction),
    do:
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_030_203_830,
        module,
        :forward,
        operation,
        direction,
        log: false
      )
end
