defmodule SchedulerApi.AppointmentTeamsTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Employment}

  alias SchedulerApi.Appointments.{
    Appointment,
    JobAssignments,
    JobAssignment,
    JobAssignmentAuditEvent
  }

  alias SchedulerApi.Employment.{WorkSchedules, WorkShift}
  alias SchedulerApi.Organizations.{Memberships, Shop}
  setup do: job_fixture()
  defp job(dto), do: %JobAssignment{id: dto.id}

  defp add(c, assignment \\ nil),
    do: JobAssignments.add_member(c.credential, c.booking, assignment || c.assignment)

  defp roster(c), do: JobAssignments.list_team(c.owner, c.booking)

  test "zero, one, two and many independent members without inferred leads", c do
    assert {:ok, %{assignments: [], has_more: false}} = roster(c)
    assert {:ok, first} = add(c)

    for _ <- 1..4 do
      next = second_detailer(c)
      assert {:ok, member} = add(c, next.assignment)
      refute member.is_lead
    end

    assert {:ok, %{assignments: members}} = roster(c)
    assert length(members) == 5
    assert Enum.all?(members, &(&1.status == :active and not &1.is_lead))
    assert {:error, :already_assigned} = add(c)
    assert {:ok, removed} = JobAssignments.remove_member(c.credential, c.booking, job(first))
    assert removed.status == :unassigned
    assert {:ok, %{assignments: remaining}} = roster(c)
    assert length(remaining) == 4
    assert Enum.map(remaining, & &1.id) == Enum.map(tl(members), & &1.id)

    assert {:error, :not_assigned} =
             JobAssignments.remove_member(c.credential, c.booking, job(first))

    # Re-adding creates a new immutable row, never resurrects history.
    assert {:ok, new} = add(c)
    assert new.id != first.id
    assert Repo.get!(JobAssignment, first.id).status == :unassigned
  end

  test "lead designation, atomic transfer, clearing and removal preserve explicit history", c do
    {:ok, first} = add(c)
    next = second_detailer(c)
    {:ok, second} = add(c, next.assignment)
    assert {:error, :no_lead} = JobAssignments.clear_lead(c.credential, c.booking)
    assert {:ok, lead} = JobAssignments.designate_lead(c.credential, c.booking, job(first))
    assert lead.is_lead

    assert {:error, :already_lead} =
             JobAssignments.designate_lead(c.credential, c.booking, job(first))

    assert {:ok, lead} = JobAssignments.designate_lead(c.credential, c.booking, job(second))
    assert lead.id == second.id and lead.is_lead
    refute Repo.get!(JobAssignment, first.id).is_lead
    assert {:ok, _} = JobAssignments.clear_lead(c.credential, c.booking)
    assert {:ok, _} = JobAssignments.designate_lead(c.credential, c.booking, job(second))
    assert {:ok, removed} = JobAssignments.remove_member(c.credential, c.booking, job(second))
    refute removed.is_lead
    assert {:ok, %{assignments: [last]}} = roster(c)
    assert last.id == first.id and not last.is_lead

    events =
      Repo.all(from a in JobAssignmentAuditEvent, where: a.outcome == :applied, order_by: a.id)

    assert Enum.map(events, &{&1.action, &1.previous_lead_job_id, &1.lead_job_id}) == [
             {:add_member, nil, nil},
             {:add_member, nil, nil},
             {:designate_lead, nil, first.id},
             {:designate_lead, first.id, second.id},
             {:clear_lead, second.id, nil},
             {:designate_lead, nil, second.id},
             {:remove_member, second.id, nil}
           ]
  end

  test "legacy APIs preserve single-assignee behavior and refuse ambiguous team changes", c do
    assert {:ok, first} = JobAssignments.assign(c.credential, c.booking, c.assignment)
    assert {:ok, _} = JobAssignments.designate_lead(c.credential, c.booking, job(first))
    next = second_detailer(c)
    assert {:ok, replacement} = JobAssignments.reassign(c.credential, c.booking, next.assignment)
    refute replacement.is_lead
    assert Repo.get!(JobAssignment, first.id).status == :reassigned
    assert {:ok, _} = add(c)

    assert {:error, :already_assigned} =
             JobAssignments.assign(c.credential, c.booking, c.assignment)

    assert {:error, :ambiguous_team} =
             JobAssignments.reassign(c.credential, c.booking, c.assignment)

    assert {:error, :ambiguous_team} = JobAssignments.unassign(c.credential, c.booking)
    assert {:ok, %{assignments: members}} = roster(c)
    assert length(members) == 2
    assert {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, job(replacement))
    assert {:ok, _} = JobAssignments.unassign(c.credential, c.booking)
    assert {:ok, %{assignments: []}} = roster(c)
  end

  test "lead must be an active member of this exact persisted appointment", c do
    foreign = job_fixture()
    {:ok, other} = add(foreign)

    assert {:error, :not_assigned} =
             JobAssignments.designate_lead(c.credential, c.booking, job(other))

    assert {:error, :not_assigned} =
             JobAssignments.remove_member(c.credential, c.booking, %{
               job(other)
               | appointment_id: c.booking.id
             })

    assert {:error, :forbidden} =
             JobAssignments.designate_lead(c.credential, foreign.booking, job(other))

    assert {:ok, member} = add(c)
    assert {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, job(member))

    assert {:error, :not_assigned} =
             JobAssignments.designate_lead(c.credential, c.booking, job(member))

    assert {:ok, %{assignments: []}} = roster(c)
  end

  test "every added Detailer independently needs correct classification, shop and shift", c do
    {:ok, _} = add(c)
    management = second_detailer(c, %{classification: :shop_manager})
    assert {:error, :ineligible_detailer} = add(c, management.assignment)
    next = second_detailer(c)
    {:ok, _} = WorkSchedules.cancel_shift(c.credential, %WorkShift{id: next.shift.id})
    assert {:error, :missing_covering_shift} = add(c, next.assignment)
    wrong = shop_fixture(%{business_id: c.business.id})
    {:ok, a} = Employment.assign_shop(next.employment, wrong, %{starts_on: ~D[2026-01-01]})
    assert {:error, :ineligible_detailer} = add(c, a)
    foreign = job_fixture()
    assert {:error, :ineligible_detailer} = add(c, foreign.assignment)
    assert {:ok, %{assignments: [_]}} = roster(c)
  end

  test "Owner/assigned Shop Manager access uses complete grants; own work excludes coworkers",
       c do
    {:ok, first} = add(c)
    next = second_detailer(c)
    {:ok, _} = add(c, next.assignment)
    assert {:ok, %{assignments: [own]}} = JobAssignments.list_own_work(c.detailer, c.business)
    assert own.id == first.id
    assert {:error, :forbidden} = JobAssignments.list_team(c.detailer, c.booking)
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    assert {:ok, %{assignments: members}} = JobAssignments.list_team(sm, c.booking)
    assert length(members) == 2
    {:ok, _, credential} = Accounts.create_session(sm)
    assert {:ok, _} = JobAssignments.designate_lead(credential, c.booking, job(first))

    for role <- [:business_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      {:ok, _, token} = Accounts.create_session(user)
      assert {:error, :forbidden} = JobAssignments.remove_member(token, c.booking, job(first))
      assert {:error, :forbidden} = JobAssignments.designate_lead(token, c.booking, job(first))
      assert {:error, :forbidden} = JobAssignments.list_team(user, c.booking)
    end

    other = job_fixture()
    grant_fixture(sm, other.shop, :employee)
    assert {:error, :forbidden} = JobAssignments.list_team(sm, other.booking)

    for member <- members,
        field <- [
          :customer_email,
          :customer_phone,
          :home_address,
          :amount,
          :user,
          :email,
          :token,
          :notes
        ],
        do: refute(Map.has_key?(member, field))
  end

  test "complete team protects appointment and shifts until every affected member is removed",
       c do
    {:ok, first} = add(c)
    next = second_detailer(c)
    {:ok, second} = add(c, next.assignment)
    {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, job(first))
    assert {:ok, _} = WorkSchedules.cancel_shift(c.credential, %WorkShift{id: c.shift.id})

    assert {:error, :assigned_jobs} =
             WorkSchedules.cancel_shift(c.credential, %WorkShift{id: next.shift.id})

    assert {:error, :assigned_jobs} =
             WorkSchedules.reschedule_shift(c.credential, %WorkShift{id: next.shift.id}, %{
               starts_at: next.shift.starts_at,
               ends_at: DateTime.add(next.shift.ends_at, 3600)
             })

    for update <- [
          "duration_minutes=120",
          "starts_at=starts_at+interval '1 hour'",
          "status='cancelled'"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{constraint: "appointments_active_jobs"}}} =
               Repo.query("UPDATE appointments SET #{update} WHERE id=$1", [c.booking.id],
                 mode: :savepoint
               )
    end

    {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, job(second))

    assert {:ok, _} =
             Repo.query("UPDATE appointments SET status='cancelled' WHERE id=$1", [c.booking.id])

    assert Repo.aggregate(JobAssignment, :count) == 2
  end

  test "revocation and termination preserve history and deferred offboarding without implicit promotion",
       c do
    {:ok, first} = add(c)
    next = second_detailer(c)
    {:ok, second} = add(c, next.assignment)
    {:ok, _} = JobAssignments.designate_lead(c.credential, c.booking, job(first))
    {:ok, _} = Employment.end_employment(c.employment, Date.utc_today())
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)

    assert {:error, :ineligible_detailer} =
             JobAssignments.designate_lead(c.credential, c.booking, job(first))

    assert {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, job(first))
    assert Repo.get!(JobAssignment, first.id).status == :unassigned
    refute Repo.get!(JobAssignment, second.id).is_lead
    assert Repo.get!(WorkShift, c.shift.id)
    assert Repo.get!(Appointment, c.booking.id)
    {:ok, _} = Memberships.revoke(c.membership)

    assert {:error, :forbidden} =
             JobAssignments.remove_member(c.credential, c.booking, job(second))
  end

  test "team pagination does not hide an implicit crew limit or leak other appointments", c do
    for a <- [c.assignment, second_detailer(c).assignment, second_detailer(c).assignment],
        do: assert({:ok, _} = add(c, a))

    assert {:ok, %{assignments: first, has_more: true, next_cursor: cursor}} =
             JobAssignments.list_team(c.owner, c.booking, limit: 2)

    assert {:ok, %{assignments: [last], has_more: false, next_cursor: nil}} =
             JobAssignments.list_team(c.owner, c.booking, limit: 2, cursor: cursor)

    assert length(Enum.uniq(Enum.map(first ++ [last], & &1.id))) == 3
    assert {:error, :invalid_options} = JobAssignments.list_team(c.owner, c.booking, limit: 0)

    assert {:error, :invalid_options} =
             JobAssignments.list_team(c.owner, c.booking, cursor: "invalid")

    Repo.update_all(from(s in Shop, where: s.id == ^c.shop.id), set: [status: :archived])
    assert {:error, :forbidden} = roster(c)
  end

  test "Employee grants never make management staff eligible Detailers", c do
    user = active_user_fixture()
    grant_fixture(user, c.shop, :employee)

    e =
      SchedulerApi.EmploymentFixtures.employment_fixture(%{classification: :shop_manager},
        business: c.business,
        user: user
      )

    {:ok, a} = Employment.assign_shop(e, c.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, _} =
      WorkSchedules.create_shift(c.credential, a, %{
        starts_at: c.shift.starts_at,
        ends_at: c.shift.ends_at
      })

    assert {:error, :ineligible_detailer} = add(c, a)
    assert {:ok, %{assignments: []}} = roster(c)
  end

  test "a member's cross-shop overlapping job blocks only that employee, not the whole team", c do
    {:ok, first} = add(c)
    %{shop: other, price: price} = shop_price_fixture(c.price)
    {:ok, a} = Employment.assign_shop(c.employment, other, %{starts_on: ~D[2026-01-01]})
    attrs = SchedulerApi.AppointmentsFixtures.booking_attrs(price)
    attrs = %{attrs | starts_at: DateTime.add(c.booking.starts_at, 3600)}
    {:ok, booking} = SchedulerApi.Appointments.create_appointment(other, attrs)
    assert {:error, :overlap} = JobAssignments.add_member(c.credential, booking, a)
    assert Repo.get!(JobAssignment, first.id).status == :active
    next = second_detailer(c)
    assert {:ok, _} = add(c, next.assignment)
    assert {:ok, %{assignments: members}} = roster(c)
    assert length(members) == 2
  end
end
