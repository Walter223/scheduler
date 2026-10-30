defmodule SchedulerApi.OffboardingTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  alias SchedulerApi.{Accounts, Employment, Authorization}

  alias SchedulerApi.Employment.{
    HR,
    WorkSchedules,
    WorkShift,
    OffboardingAudit,
    ClassificationHistory,
    Compensation
  }

  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment}
  alias SchedulerApi.Organizations.BusinessMembership
  setup do: job_fixture()

  test "terminates only target team member, cleans multiple future jobs/shifts and preserves pay/history",
       c do
    next = second_detailer(c)
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    {:ok, other} = JobAssignments.add_member(c.credential, c.booking, next.assignment)
    {:ok, _} = JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: j.id})

    {:ok, second} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: DateTime.add(c.shift.starts_at, 86400),
        ends_at: DateTime.add(c.shift.ends_at, 86400)
      })

    date = Date.add(SchedulerApi.AppointmentsFixtures.booking_date(), 2)
    date = if Date.day_of_week(date) == 7, do: Date.add(date, 1), else: date

    {:ok, extra_booking} =
      SchedulerApi.Appointments.create_appointment(
        c.shop,
        SchedulerApi.AppointmentsFixtures.booking_attrs(c.price, date)
      )

    {:ok, extra_shift} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: extra_booking.starts_at,
        ends_at: DateTime.add(extra_booking.starts_at, 8 * 3600)
      })

    {:ok, extra_job} = JobAssignments.add_member(c.credential, extra_booking, c.assignment)
    past_start = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3 * 86400)

    {:ok, past_shift} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: past_start,
        ends_at: DateTime.add(past_start, 3600)
      })

    assert {:ok, _} =
             Compensation.set_rate(c.credential, c.employment, %{
               amount: "25.00",
               pay_basis: :hourly,
               effective_from: Date.utc_today()
             })

    before = Repo.all(ClassificationHistory)

    assert {:ok, %{already_terminated: false, employment: %{status: :ended}}} =
             HR.terminate_employment(c.credential, c.employment)

    assert Repo.get!(JobAssignment, j.id).status == :unassigned
    assert Repo.get!(JobAssignment, other.id).status == :active
    refute Repo.get!(JobAssignment, other.id).is_lead
    assert Repo.get!(WorkShift, c.shift.id).status == :cancelled
    assert Repo.get!(WorkShift, second.id).status == :cancelled
    assert Repo.get!(WorkShift, extra_shift.id).status == :cancelled
    assert Repo.get!(JobAssignment, extra_job.id).status == :unassigned
    assert Repo.get!(WorkShift, past_shift.id).status == :active
    summary = Repo.one!(OffboardingAudit)
    assert summary.jobs_removed == 2 and summary.shifts_cancelled == 3

    assert Repo.reload!(c.assignment).status == :ended
    assert Repo.reload!(c.employee_membership).status == :revoked
    assert Repo.reload!(c.detailer).status == :active
    assert Repo.all(ClassificationHistory) == before
    assert {:ok, [_]} = Compensation.list_rate_history(c.owner, c.employment)
    assert {:ok, %{employments: active}} = Employment.list_business_roster(c.owner, c.business)
    refute Enum.any?(active, &(&1.id == c.employment.id))
    assert {:ok, [former]} = HR.list_former_employees(c.owner, c.business)
    assert former.id == c.employment.id

    assert {:ok, %{already_terminated: true}} =
             HR.terminate_employment(c.credential, c.employment)

    assert Repo.aggregate(OffboardingAudit, :count) == 1
  end

  test "Business Manager can offboard linked employee without general scheduling or access-management permission",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {:ok, _, credential} = Accounts.create_session(manager)
    assert {:error, :forbidden} = Authorization.authorize(manager, :schedule_manage, c.shop)
    assert {:error, :forbidden} = Authorization.authorize(manager, :access_manage, c.business)
    assert {:ok, _} = HR.terminate_employment(credential, c.employment)
    assert Repo.reload!(c.employee_membership).status == :revoked
  end

  test "unlinked employment can terminate without inventing a user or membership", c do
    next = second_detailer(c)
    assert {:ok, _} = HR.terminate_employment(c.credential, next.employment)
    assert Repo.aggregate(SchedulerApi.Accounts.User, :count) == 2
    assert Repo.aggregate(BusinessMembership, :count) == 2
    assert Repo.one!(OffboardingAudit).membership_id == nil
  end

  test "unrelated business membership and global session remain intact", c do
    foreign = job_fixture()
    {membership, _} = grant_fixture(c.detailer, foreign.shop, :shop_manager)
    {:ok, _, token} = Accounts.create_session(c.detailer)
    assert {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    assert Repo.reload!(membership).status == :active
    assert :ok = Authorization.authorize(c.detailer, :schedule_manage, foreign.shop)

    assert {:ok, _} =
             Accounts.get_session_by_token(SchedulerApi.Accounts.SessionCredential.reveal(token))
  end

  test "last Owner cannot be terminated even by HR; all cleanup rolls back", c do
    e =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: c.owner)

    {:ok, owner_assignment} = Employment.assign_shop(e, c.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, owner_shift} =
      WorkSchedules.create_shift(c.credential, owner_assignment, %{
        starts_at: c.shift.starts_at,
        ends_at: c.shift.ends_at
      })

    assert {:error, :last_owner} = HR.terminate_employment(c.credential, e)
    assert Repo.get!(WorkShift, owner_shift.id).status == :active
    assert Repo.reload!(owner_assignment).status == :active

    assert Repo.reload!(e).status == :active
    assert Repo.reload!(c.membership).status == :active
    assert Repo.aggregate(OffboardingAudit, :count) == 0
  end

  test "Business Manager cannot revoke protected Owner access even with another Owner", c do
    e =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: c.owner)

    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    second = active_user_fixture()
    grant_fixture(second, c.shop, :business_owner)
    {:ok, _, token} = Accounts.create_session(manager)
    assert {:error, :forbidden} = HR.terminate_employment(token, e)
    assert Repo.reload!(c.membership).status == :active
  end

  test "Shop Manager and foreign tenants denied; stale struct ownership is not proof", c do
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    {:ok, _, token} = Accounts.create_session(sm)
    assert {:error, :forbidden} = HR.terminate_employment(token, c.employment)
    assert {:error, :forbidden} = HR.terminate_employment(c.owner, c.employment)
    foreign = job_fixture()

    assert {:error, :forbidden} =
             HR.terminate_employment(c.credential, %{
               foreign.employment
               | business_id: c.business.id
             })

    assert {:error, :forbidden} = HR.list_former_employees(sm, c.business)
  end

  test "an in-progress shift refuses offboarding without partial cleanup", c do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: DateTime.add(now, -60),
        ends_at: DateTime.add(now, 60)
      })

    assert {:error, :work_in_progress} = HR.terminate_employment(c.credential, c.employment)
    assert Repo.reload!(c.employment).status == :active
    assert Repo.get!(WorkShift, c.shift.id).status == :active
  end

  test "final audit failure rolls back child work audits, access and termination", c do
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)

    Repo.query!(
      "ALTER TABLE employment_offboarding_audits ADD CONSTRAINT test_offboarding_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} = HR.terminate_employment(c.credential, c.employment)
    assert Repo.reload!(c.employment).status == :active
    assert Repo.reload!(c.assignment).status == :active
    assert Repo.reload!(c.employee_membership).status == :active
    assert Repo.get!(JobAssignment, j.id).status == :active
    assert Repo.get!(WorkShift, c.shift.id).status == :active
    assert Repo.aggregate(OffboardingAudit, :count) == 0
  end

  test "scheduling audit failure also rolls back jobs and their lead flags", c do
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    {:ok, _} = JobAssignments.designate_lead(c.credential, c.booking, %JobAssignment{id: j.id})

    Repo.query!(
      "ALTER TABLE work_shift_audit_events ADD CONSTRAINT test_offboarding_child_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} = HR.terminate_employment(c.credential, c.employment)
    assert Repo.get!(JobAssignment, j.id).is_lead
    assert Repo.get!(WorkShift, c.shift.id).status == :active
    assert Repo.reload!(c.employee_membership).status == :active
  end

  test "RBAC audit failure rolls back earlier job/shift cleanup and all access changes", c do
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)

    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_access_offboarding_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} = HR.terminate_employment(c.credential, c.employment)
    assert Repo.reload!(c.employee_membership).status == :active
    assert Repo.reload!(c.employment).status == :active
    assert Repo.get!(JobAssignment, j.id).status == :active
    assert Repo.get!(WorkShift, c.shift.id).status == :active
  end

  test "legacy ended employment is not falsely reported as securely offboarded", c do
    {:ok, _} = Employment.end_employment(c.employment, Date.utc_today())

    assert {:error, :legacy_termination_requires_review} =
             HR.terminate_employment(c.credential, c.employment)

    assert Repo.reload!(c.employee_membership).status == :active
    assert Repo.aggregate(OffboardingAudit, :count) == 0
  end
end
