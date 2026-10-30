defmodule SchedulerApi.AppointmentTeamIntegrityTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment, JobAssignmentAuditEvent}
  setup do: job_fixture()

  test "lead flags are constrained to one active member and closed identity/history remains immutable",
       c do
    {:ok, first} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    next = second_detailer(c)
    {:ok, second} = JobAssignments.add_member(c.credential, c.booking, next.assignment)

    assert {:ok, _} =
             Repo.query("UPDATE appointment_assignments SET is_lead=true WHERE id=$1", [first.id])

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :unique_violation, constraint: "appointment_jobs_one_lead"}
            }} =
             Repo.query(
               "UPDATE appointment_assignments SET is_lead=true WHERE id=$1",
               [second.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE appointment_assignments SET employment_id=employment_id+1000,is_lead=false WHERE id=$1",
               [first.id],
               mode: :savepoint
             )

    {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, %JobAssignment{id: first.id})

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE appointment_assignments SET is_lead=true WHERE id=$1", [first.id],
               mode: :savepoint
             )

    assert Repo.get!(JobAssignment, second.id).status == :active
  end

  test "lead audit references cannot cross appointments or rewrite durable history", c do
    {:ok, first} = JobAssignments.add_member(c.credential, c.booking, c.assignment)

    {:ok, _} =
      JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: first.id})

    foreign = job_fixture()

    {:ok, other} =
      JobAssignments.add_member(foreign.credential, foreign.booking, foreign.assignment)

    event = Repo.one!(from a in JobAssignmentAuditEvent, where: a.action == :designate_lead)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "INSERT INTO appointment_assignment_audit_events(actor_user_id,appointment_id,business_id,shop_id,job_id,lead_job_id,action,outcome,reason,occurred_at) VALUES($1,$2,$3,$4,$5,$6,'designate_lead','applied','lead_designated',$7)",
               [
                 c.owner.id,
                 c.booking.id,
                 c.business.id,
                 c.shop.id,
                 first.id,
                 other.id,
                 DateTime.to_naive(event.occurred_at)
               ],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE appointment_assignment_audit_events SET lead_job_id=NULL WHERE id=$1",
               [event.id],
               mode: :savepoint
             )
  end
end
