defmodule SchedulerApi.JobAssignmentIntegrityTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.{Employment, Repo}
  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment, JobAssignmentAuditEvent}
  alias SchedulerApi.Employment.WorkSchedules
  setup do: job_fixture()

  defp insert(c, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          appointment_id: c.booking.id,
          assignment_id: c.assignment.id,
          employment_id: c.employment.id,
          business_id: c.business.id,
          shop_id: c.shop.id,
          work_shift_id: c.shift.id,
          starts_at: DateTime.to_naive(c.booking.starts_at),
          ends_at: c.booking.starts_at |> DateTime.add(90 * 60) |> DateTime.to_naive(),
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
        },
        overrides
      )

    fields = [
      :appointment_id,
      :assignment_id,
      :employment_id,
      :business_id,
      :shop_id,
      :work_shift_id,
      :starts_at,
      :ends_at,
      :inserted_at
    ]

    Repo.query(
      "INSERT INTO appointment_assignments (#{Enum.join(fields, ",")}) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
      Enum.map(fields, &Map.fetch!(attrs, &1)),
      mode: :savepoint,
      log: false
    )
  end

  test "direct inserts enforce appointment, employment, shop and covering-shift composite identities",
       c do
    foreign = job_fixture()

    for attrs <- [
          %{business_id: foreign.business.id},
          %{shop_id: foreign.shop.id},
          %{assignment_id: foreign.assignment.id},
          %{work_shift_id: foreign.shift.id},
          %{employment_id: foreign.employment.id}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert(c, attrs)
    end

    assert Repo.aggregate(JobAssignment, :count) == 0
    assert {:ok, _} = insert(c)
    # The unique grant and employee exclusion both protect the duplicate. Assert
    # the actual unique constraint, and inspect the separate exclusion below.
    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :unique_violation, constraint: "appointment_jobs_one_active"}
            }} = insert(c)

    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='appointment_jobs_no_overlap'"
      )

    assert definition =~ "business_id WITH ="
    assert definition =~ "employment_id WITH ="
    assert definition =~ "tsrange(starts_at, ends_at, '[)'::text) WITH &&"
    assert definition =~ "active"
  end

  test "database eligibility rejects management classification, ended employment and forged periods",
       c do
    manager = second_detailer(c, %{classification: :shop_manager})

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "appointment_jobs_eligible"}
            }} =
             insert(c, %{
               employment_id: manager.employment.id,
               assignment_id: manager.assignment.id,
               work_shift_id: manager.shift.id
             })

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "appointment_jobs_snapshot"}
            }} =
             insert(c, %{
               ends_at: c.booking.starts_at |> DateTime.add(3600) |> DateTime.to_naive()
             })

    {:ok, _} = Employment.end_employment(c.employment, Date.utc_today())

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "appointment_jobs_eligible"}
            }} = insert(c)
  end

  test "database blocks invalid shift coverage, cancellation and appointment snapshot drift", c do
    {:ok, _} =
      WorkSchedules.cancel_shift(c.credential, %SchedulerApi.Employment.WorkShift{id: c.shift.id})

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "appointment_jobs_shift_coverage"}
            }} = insert(c)

    {:ok, s} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: c.booking.starts_at,
        ends_at: DateTime.add(c.booking.starts_at, 90 * 60)
      })

    assert {:ok, _} = insert(c, %{work_shift_id: s.id})

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "work_shifts_active_jobs"}
            }} =
             Repo.query(
               "UPDATE work_shifts SET status='cancelled',closed_at=now() AT TIME ZONE 'UTC' WHERE id=$1",
               [s.id],
               mode: :savepoint
             )

    for change <- [
          "duration_minutes=120",
          "starts_at=starts_at+interval '1 hour'",
          "status='cancelled'",
          "status='completed'"
        ] do
      assert {:error,
              %Postgrex.Error{
                postgres: %{code: :check_violation, constraint: "appointments_active_jobs"}
              }} =
               Repo.query(
                 "UPDATE appointments SET #{change} WHERE id=$1",
                 [c.booking.id],
                 mode: :savepoint
               )
    end

    # Confirming is safe: occupied period remains unchanged.
    assert {:ok, _} =
             Repo.query("UPDATE appointments SET status='confirmed' WHERE id=$1", [c.booking.id])
  end

  test "history foreign keys are restrictive and audits cannot cross appointments", c do
    {:ok, j} = JobAssignments.assign(c.credential, c.booking, c.assignment)

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM appointments WHERE id=$1", [c.booking.id], mode: :savepoint)

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM appointment_assignments WHERE id=$1", [j.id],
               mode: :savepoint
             )

    foreign = job_fixture()
    event = Repo.one!(JobAssignmentAuditEvent)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "INSERT INTO appointment_assignment_audit_events(actor_user_id,appointment_id,business_id,shop_id,job_id,action,outcome,reason,occurred_at) VALUES($1,$2,$3,$4,$5,'unassign','denied','forbidden',$6)",
               [
                 c.owner.id,
                 foreign.booking.id,
                 foreign.business.id,
                 foreign.shop.id,
                 j.id,
                 DateTime.to_naive(event.occurred_at)
               ],
               mode: :savepoint
             )
  end
end
