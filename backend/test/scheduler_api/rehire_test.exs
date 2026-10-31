defmodule SchedulerApi.RehireTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Employment, Repo, Authorization}

  alias SchedulerApi.Employment.{
    HR,
    EmploymentRecord,
    RehireAudit,
    Compensation,
    WorkSchedules,
    WorkShift,
    ShopAssignment
  }

  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Memberships}
  setup do: job_fixture()
  defp next_date, do: Date.add(Date.utc_today(), 1)
  defp terminate(c), do: HR.terminate_employment(c.credential, c.employment)

  test "rehire creates empty independent period and restores nothing, including after explicit grants",
       c do
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)

    {:ok, _} =
      Compensation.set_rate(c.credential, c.employment, %{
        amount: "25.00",
        pay_basis: :hourly,
        effective_from: Date.utc_today()
      })

    {:ok, _} =
      HR.update_contact(c.credential, c.employment, %{home_address: "Prior private address"})

    {:ok, _, old_token} = Accounts.create_session(c.detailer)
    {:ok, _} = terminate(c)

    before =
      {Repo.aggregate(ShopAssignment, :count), Repo.aggregate(WorkShift, :count),
       Repo.aggregate(JobAssignment, :count)}

    assert {:ok, new} = HR.rehire_employment(c.credential, c.employment, next_date())
    assert new.employee_id == c.employment.id and new.id != c.employment.id
    assert Repo.reload!(c.employment).status == :ended
    period = Repo.get!(EmploymentRecord, new.id)
    assert period.user_id == c.detailer.id and period.home_address == nil
    assert Repo.reload!(c.employee_membership).status == :revoked

    assert {Repo.aggregate(ShopAssignment, :count), Repo.aggregate(WorkShift, :count),
            Repo.aggregate(JobAssignment, :count)} == before

    assert Repo.get!(JobAssignment, j.id).status == :unassigned
    assert {:error, :forbidden} = Compensation.get_own_current_rate(c.detailer, c.business)
    assert {:error, :forbidden} = WorkSchedules.list_own_shifts(c.detailer, c.business)
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)

    assert {:ok, _} =
             Accounts.get_session_by_token(
               SchedulerApi.Accounts.SessionCredential.reveal(old_token)
             )

    # Access restoration is a separate explicit audited Owner operation.
    {:ok, _} =
      RoleManagement.reactivate_membership(
        c.credential,
        c.business,
        Repo.reload!(c.employee_membership)
      )

    {:ok, _} =
      RoleManagement.grant_role(
        c.credential,
        c.business,
        Repo.reload!(c.employee_membership),
        :employee,
        c.shop
      )

    {:ok, a} = HR.assign_shop(c.credential, period, c.shop, %{starts_on: next_date()})
    assert a.id != c.assignment.id
    future = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3 * 86400)
    assert {:ok, nil} = Compensation.get_own_current_rate(c.detailer, c.business, now: future)
    assert {:ok, %{shifts: []}} = WorkSchedules.list_own_shifts(c.detailer, c.business)
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)
    assert {:error, :forbidden} = WorkSchedules.get_shift(c.detailer, %WorkShift{id: c.shift.id})

    assert {:error, :forbidden} =
             Authorization.authorize(c.detailer, :jobs_assigned_read, %JobAssignment{id: j.id})

    assert {:error, :forbidden} =
             Compensation.get_current_rate(c.detailer, c.employment, now: future)

    assert {:error, :forbidden} = HR.list_employment_history(c.detailer, period)
    assert {:ok, history} = HR.list_employment_history(c.owner, period)
    assert Enum.map(history, & &1.id) == [c.employment.id, new.id]
    assert {:ok, [_]} = Compensation.list_rate_history(c.owner, c.employment)

    assert {:ok, %{employments: [current]}} =
             Employment.list_business_roster(c.owner, c.business, now: future)

    assert current.id == new.id
    assert {:ok, [former]} = HR.list_former_employees(c.owner, c.business)
    assert former.id == c.employment.id
  end

  test "two businesses with distinct Owners preserve independent linked employment and work", c do
    foreign = job_fixture()
    {other_member, _} = grant_fixture(c.detailer, foreign.shop, :employee)
    other = employment_fixture(%{}, business: foreign.business, user: c.detailer)
    {:ok, assignment} = Employment.assign_shop(other, foreign.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, shift} =
      WorkSchedules.create_shift(foreign.credential, assignment, %{
        starts_at: foreign.shift.starts_at,
        ends_at: foreign.shift.ends_at
      })

    {:ok, job} = JobAssignments.add_member(foreign.credential, foreign.booking, assignment)
    {:ok, _} = terminate(c)
    assert {:ok, _} = HR.rehire_employment(c.credential, c.employment, next_date())
    assert Repo.reload!(other_member).status == :active
    assert Repo.reload!(other).status == :active
    assert Repo.get!(WorkShift, shift.id).status == :active
    assert Repo.get!(JobAssignment, job.id).status == :active

    assert {:ok, %{assignments: [own]}} =
             JobAssignments.list_own_work(c.detailer, foreign.business)

    assert own.id == job.id

    assert {:error, :forbidden} =
             HR.rehire_employment(foreign.credential, c.employment, next_date())
  end

  test "two prior shops remain ended and are never restored", c do
    shop = shop_fixture(%{business_id: c.business.id})
    {:ok, second} = HR.assign_shop(c.credential, c.employment, shop, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = terminate(c)
    {:ok, new} = HR.rehire_employment(c.credential, c.employment, next_date())
    assert Repo.get!(ShopAssignment, second.id).status == :ended
    assert Repo.reload!(c.assignment).status == :ended
    refute Repo.exists?(from a in ShopAssignment, where: a.employment_id == ^new.id)
  end

  test "current and historical Owner protection applies to rehire; other HR classes are allowed",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {:ok, _, token} = Accounts.create_session(manager)
    owner_record = employment_fixture(%{classification: :business_owner}, business: c.business)
    {:ok, _} = HR.change_classification(c.credential, owner_record, :detailer)
    {:ok, _} = HR.terminate_employment(c.credential, owner_record)
    assert {:error, :forbidden} = HR.rehire_employment(token, owner_record, next_date())
    {:ok, new} = HR.rehire_employment(c.credential, owner_record, next_date())
    # Protection follows stable identity across periods even without user/grants.
    assert {:error, :forbidden} =
             Authorization.authorize(manager, :employment_rehire, %EmploymentRecord{id: new.id})

    e = employment_fixture(%{classification: :business_manager}, business: c.business)
    {:ok, _} = HR.terminate_employment(c.credential, e)
    assert {:ok, _} = HR.rehire_employment(token, e, next_date())
  end

  test "invalid transitions, repeat requests and unsafe dates cannot create duplicate periods",
       c do
    assert {:error, :not_latest_ended_period} =
             HR.rehire_employment(c.credential, c.employment, next_date())

    {:ok, _} = terminate(c)

    for date <- [Repo.reload!(c.employment).ends_on, "invalid", nil] do
      assert {:error, :invalid_start_date} =
               HR.rehire_employment(c.credential, c.employment, date)
    end

    {:ok, _} = HR.rehire_employment(c.credential, c.employment, next_date())

    assert {:error, :not_latest_ended_period} =
             HR.rehire_employment(c.credential, c.employment, next_date())

    assert Repo.aggregate(RehireAudit, :count) == 1
  end

  test "legacy termination must be reconciled, not silently rehired", c do
    {:ok, _} = Employment.end_employment(c.employment, Date.utc_today())

    assert {:error, :offboarding_required} =
             HR.rehire_employment(c.credential, c.employment, next_date())
  end

  test "disabled actors and revoked membership are checked; continuing target identity grants no access",
       c do
    {:ok, _} = terminate(c)
    {:ok, _} = Accounts.set_user_status(c.detailer, :suspended)
    assert {:error, :forbidden} = HR.rehire_employment(c.owner, c.employment, next_date())
    {:ok, _} = Memberships.revoke(c.membership)
    assert {:error, :forbidden} = HR.rehire_employment(c.credential, c.employment, next_date())
    assert Repo.aggregate(RehireAudit, :count) == 0
  end

  test "audit failure rolls back new period, history and all effects", c do
    {:ok, _} = terminate(c)
    count = Repo.aggregate(EmploymentRecord, :count)
    histories = Repo.aggregate(SchedulerApi.Employment.ClassificationHistory, :count)

    Repo.query!(
      "ALTER TABLE employment_rehire_audits ADD CONSTRAINT test_rehire_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             HR.rehire_employment(c.credential, c.employment, next_date())

    assert Repo.aggregate(EmploymentRecord, :count) == count
    assert Repo.aggregate(SchedulerApi.Employment.ClassificationHistory, :count) == histories
    assert Repo.reload!(c.employee_membership).status == :revoked
  end

  test "multiple historical periods retain stable identity and HR timeline", c do
    e = employment_fixture(%{}, business: c.business)
    {:ok, _} = Employment.end_employment(e, ~D[2026-01-31])
    historical_offboarding(c, e, ~D[2026-01-31])
    {:ok, second} = HR.rehire_employment(c.credential, e, ~D[2026-02-01])
    second_ref = Repo.get!(EmploymentRecord, second.id)
    {:ok, _} = Employment.end_employment(second_ref, ~D[2026-03-31])
    historical_offboarding(c, second_ref, ~D[2026-03-31])
    {:ok, third} = HR.rehire_employment(c.credential, second_ref, ~D[2026-04-01])
    assert third.employee_id == e.id
    assert {:ok, periods} = HR.list_employment_history(c.owner, %EmploymentRecord{id: third.id})
    assert Enum.map(periods, & &1.id) == [e.id, second.id, third.id]
    assert Enum.map(periods, & &1.status) == [:ended, :ended, :active]
  end

  test "database rejects duplicate active periods, cross-tenant identity and historical edits",
       c do
    {:ok, _} = terminate(c)
    {:ok, new} = HR.rehire_employment(c.credential, c.employment, next_date())

    assert {:error, %Postgrex.Error{postgres: %{constraint: "employments_rehire_valid"}}} =
             Repo.query(
               "INSERT INTO employments(employee_id,business_id,user_id,first_name,last_name,classification,status,starts_on,inserted_at,updated_at) SELECT employee_id,business_id,user_id,first_name,last_name,classification,'active',starts_on,inserted_at,updated_at FROM employments WHERE id=$1",
               [new.id],
               mode: :savepoint
             )

    other = job_fixture()

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "INSERT INTO employments(employee_id,business_id,first_name,last_name,classification,status,starts_on,inserted_at,updated_at) VALUES($1,$2,'A','B','detailer','active','2026-01-01',now(),now())",
               [c.employment.id, other.business.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE employments SET employee_id=$1 WHERE id=$2",
               [other.employment.id, new.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE employments SET status='active',ends_on=NULL WHERE id=$1",
               [c.employment.id],
               mode: :savepoint
             )
  end

  test "rehiring a previously linked suspended identity does not activate account or membership",
       c do
    {:ok, _} = terminate(c)
    {:ok, _} = Accounts.set_user_status(c.detailer, :suspended)
    assert {:ok, new} = HR.rehire_employment(c.credential, c.employment, next_date())
    assert Repo.get!(EmploymentRecord, new.id).user_id == c.detailer.id
    assert Repo.reload!(c.detailer).status == :suspended
    assert Repo.reload!(c.employee_membership).status == :revoked
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)
  end

  test "effective current period with explicit new grants cannot read prior pay, shifts or job IDs",
       c do
    user = active_user_fixture()
    {member, _} = grant_fixture(user, c.shop, :employee)
    old = employment_fixture(%{}, business: c.business, user: user)
    {:ok, assigned} = Employment.assign_shop(old, c.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, shift} =
      WorkSchedules.create_shift(c.credential, assigned, %{
        starts_at: ~U[2026-01-10 16:00:00Z],
        ends_at: ~U[2026-01-10 20:00:00Z]
      })

    booking_fields =
      Map.take(c.booking, [
        :business_id,
        :shop_id,
        :service_price_id,
        :duration_minutes,
        :price_cents,
        :customer_first_name,
        :customer_last_name,
        :customer_email,
        :customer_phone,
        :vehicle_make,
        :vehicle_model
      ])

    booking =
      Repo.insert!(
        struct!(
          SchedulerApi.Appointments.Appointment,
          Map.put(booking_fields, :starts_at, ~U[2026-01-10 16:00:00Z])
        )
      )

    {:ok, job} = JobAssignments.add_member(c.credential, booking, assigned)

    {:ok, _} =
      Compensation.set_rate(
        c.credential,
        old,
        %{amount: "40.00", pay_basis: :hourly, effective_from: ~D[2026-01-01]},
        now: ~U[2026-01-01 12:00:00Z]
      )

    # Isolated past-period fixture: retain completed work, end assignments, revoke
    # access and record its known offboarding before testing today's rehire.
    {:ok, _} = Employment.end_employment(old, ~D[2026-01-31])
    {:ok, _} = Memberships.revoke(member)
    historical_offboarding(c, old, ~D[2026-01-31])
    # Employment eligibility uses the Denver business date, not UTC midnight.
    today =
      DateTime.utc_now()
      |> SchedulerApi.Appointments.Availability.local_datetime()
      |> NaiveDateTime.to_date()

    {:ok, new} = HR.rehire_employment(c.credential, old, today)

    {:ok, _} =
      RoleManagement.reactivate_membership(c.credential, c.business, Repo.reload!(member))

    {:ok, _} =
      RoleManagement.grant_role(c.credential, c.business, Repo.reload!(member), :employee, c.shop)

    current = Repo.get!(EmploymentRecord, new.id)
    {:ok, _} = HR.assign_shop(c.credential, current, c.shop, %{starts_on: today})
    assert {:ok, nil} = Compensation.get_own_current_rate(user, c.business)
    assert {:ok, %{shifts: []}} = WorkSchedules.list_own_shifts(user, c.business)
    assert {:ok, %{assignments: []}} = JobAssignments.list_own_work(user, c.business)
    assert {:error, :forbidden} = WorkSchedules.get_shift(user, %WorkShift{id: shift.id})

    assert {:error, :forbidden} =
             Authorization.authorize(user, :jobs_assigned_read, %JobAssignment{id: job.id})

    assert {:error, :forbidden} = Compensation.list_rate_history(user, old)

    assert {:error, :forbidden} =
             Employment.get_own_employment(user, %SchedulerApi.Organizations.Business{id: -1})

    assert {:ok, own} = Employment.get_own_employment(user, c.business)
    assert own.id == new.id
  end

  defp historical_offboarding(c, e, date) do
    # Isolated historical fixture; callers explicitly close assignments/access.
    Repo.insert!(%SchedulerApi.Employment.OffboardingAudit{
      actor_user_id: c.owner.id,
      business_id: c.business.id,
      employment_id: e.id,
      ended_on: date,
      jobs_removed: 0,
      shifts_cancelled: 0,
      assignments_ended: 0,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
