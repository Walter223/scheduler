defmodule SchedulerApi.JobAssignmentAuditTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment, JobAssignmentAuditEvent}
  setup do: job_fixture()

  test "audit failure rolls back assignment and a denied attempt", c do
    Repo.query!(
      "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT test_job_audit_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             JobAssignments.assign(c.credential, c.booking, c.assignment)

    assert {:error, :persistence_failed} = JobAssignments.assign(nil, c.booking, c.assignment)
    assert Repo.aggregate(JobAssignment, :count) == 0
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 0
  end

  test "audit failure restores original job during reassignment and unassignment", c do
    {:ok, old} = JobAssignments.assign(c.credential, c.booking, c.assignment)
    next = second_detailer(c)

    Repo.query!(
      "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT test_job_audit_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             JobAssignments.reassign(c.credential, c.booking, next.assignment)

    assert {:error, :persistence_failed} = JobAssignments.unassign(c.credential, c.booking)
    assert Repo.get!(JobAssignment, old.id).status == :active
    assert Repo.aggregate(JobAssignment, :count) == 1
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 1
  end

  test "replacement persistence failure also restores original and writes no success audit", c do
    {:ok, old} = JobAssignments.assign(c.credential, c.booking, c.assignment)
    next = second_detailer(c)

    Repo.query!(
      "ALTER TABLE appointment_assignments ADD CONSTRAINT test_job_insert_failure CHECK(employment_id <> #{next.employment.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             JobAssignments.reassign(c.credential, c.booking, next.assignment)

    assert Repo.get!(JobAssignment, old.id).status == :active
    assert Repo.aggregate(JobAssignment, :count) == 1
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 1
  end

  test "audit failure rolls back every team operation and both sides of lead transfer", c do
    {:ok, first} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    next = second_detailer(c)
    {:ok, second} = JobAssignments.add_member(c.credential, c.booking, next.assignment)

    {:ok, _} =
      JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: first.id})

    third = second_detailer(c)
    before = Repo.all(from j in JobAssignment, order_by: j.id)
    events = Repo.aggregate(JobAssignmentAuditEvent, :count)

    Repo.query!(
      "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT test_team_audit_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: second.id})

    assert {:error, :persistence_failed} = JobAssignments.clear_lead(c.credential, c.booking)

    assert {:error, :persistence_failed} =
             JobAssignments.remove_member(c.credential, c.booking, %JobAssignment{id: first.id})

    assert {:error, :persistence_failed} =
             JobAssignments.add_member(c.credential, c.booking, third.assignment)

    assert {:error, :persistence_failed} =
             JobAssignments.add_member(nil, c.booking, third.assignment)

    assert Repo.all(from j in JobAssignment, order_by: j.id) == before
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == events
  end
end
