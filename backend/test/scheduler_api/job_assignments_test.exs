defmodule SchedulerApi.JobAssignmentsTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.ShopsFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.AppointmentsFixtures
  alias SchedulerApi.{Accounts, Appointments, Authorization, Employment}

  alias SchedulerApi.Appointments.{
    JobAssignments,
    JobAssignment,
    JobAssignmentAuditEvent,
    Appointment,
    Availability
  }

  alias SchedulerApi.Employment.{WorkSchedules, WorkShift}
  alias SchedulerApi.Organizations.{Memberships, Shop, Business}

  setup do: job_fixture()
  defp assign(c, a \\ nil), do: JobAssignments.assign(c.credential, c.booking, a || c.assignment)
  defp ref(c), do: %WorkShift{id: c.shift.id}

  test "Owner assigns only persisted ownership, exact snapshots, explicit projection and atomic audit",
       c do
    spoof = %{c.booking | business_id: -1, shop_id: -1}

    assert {:ok, j} =
             JobAssignments.assign(c.credential, spoof, %{c.assignment | employment_id: -1})

    assert j.business_id == c.business.id and j.shop_id == c.shop.id
    assert j.employment_id == c.employment.id and j.work_shift_id == c.shift.id
    assert j.starts_at == c.booking.starts_at
    assert j.ends_at == DateTime.add(c.booking.starts_at, 90 * 60)

    assert :ok =
             Authorization.authorize(c.owner, :jobs_assign, %JobAssignment{
               id: j.id,
               business_id: -1
             })

    assert {:ok, %{assignments: [^j], has_more: false, next_cursor: nil}} =
             JobAssignments.list_shop_assignments(c.owner, c.shop)

    event = Repo.one!(JobAssignmentAuditEvent)

    assert {event.actor_user_id, event.appointment_id, event.job_id, event.action, event.outcome,
            event.reason} == {c.owner.id, c.booking.id, j.id, :assign, :applied, "assigned"}

    for field <- [:customer_email, :home_address, :amount, :token, :notes, :user, :employment] do
      refute Map.has_key?(j, field)
    end
  end

  test "reassignment and unassignment preserve both jobs and immutable audits", c do
    {:ok, old} = assign(c)
    next = second_detailer(c)
    assert {:error, :already_assigned} = assign(c)
    assert {:error, :unchanged} = JobAssignments.reassign(c.credential, c.booking, c.assignment)
    assert {:ok, new} = JobAssignments.reassign(c.credential, c.booking, next.assignment)
    assert Repo.get!(JobAssignment, old.id).status == :reassigned
    assert new.status == :active
    assert {:ok, closed} = JobAssignments.unassign(c.credential, c.booking)
    assert closed.id == new.id and closed.status == :unassigned
    assert {:error, :not_assigned} = JobAssignments.unassign(c.credential, c.booking)
    assert Repo.aggregate(JobAssignment, :count) == 2
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 6

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE appointment_assignments SET status='active' WHERE id=$1",
               [old.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE appointment_assignment_audit_events SET reason='forbidden' WHERE job_id=$1",
               [old.id],
               mode: :savepoint
             )
  end

  test "Shop Manager assigned shop works; HR, Employee and unassigned or foreign grants fail",
       c do
    for role <- [:business_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      {:ok, _, token} = Accounts.create_session(user)
      assert {:error, :forbidden} = JobAssignments.assign(token, c.booking, c.assignment)
    end

    sm = active_user_fixture()
    other = shop_fixture(%{business_id: c.business.id})
    grant_fixture(sm, other, :shop_manager)
    {:ok, _, token} = Accounts.create_session(sm)
    assert {:error, :forbidden} = JobAssignments.assign(token, c.booking, c.assignment)
    assert {:error, :forbidden} = JobAssignments.list_shop_assignments(sm, c.shop)
    grant_fixture(sm, c.shop, :shop_manager)
    assert {:ok, j} = JobAssignments.assign(token, c.booking, c.assignment)
    assert {:ok, %{assignments: [^j]}} = JobAssignments.list_shop_assignments(sm, c.shop)
    foreign = job_fixture()
    assert {:error, :forbidden} = JobAssignments.unassign(token, foreign.booking)
    assert {:error, :forbidden} = JobAssignments.list_shop_assignments(sm, foreign.shop)
  end

  test "one complete grant supplies permission AND scope; foreign ownership cannot be borrowed",
       c do
    other = job_fixture()
    user = active_user_fixture()
    grant_fixture(user, c.shop, :employee)
    grant_fixture(user, other.shop, :business_owner)
    {:ok, _, token} = Accounts.create_session(user)
    assert {:error, :forbidden} = JobAssignments.assign(token, c.booking, c.assignment)
    assert {:error, :ineligible_detailer} = assign(c, other.assignment)
    wrongshop = shop_fixture(%{business_id: c.business.id})
    {:ok, a} = Employment.assign_shop(c.employment, wrongshop, %{starts_on: ~D[2026-01-01]})
    assert {:error, :ineligible_detailer} = assign(c, a)
  end

  test "only active Detailers with effective shop assignment may receive jobs", c do
    for classification <- [:shop_manager, :business_manager, :business_owner] do
      next = second_detailer(c, %{classification: classification})
      assert {:error, :ineligible_detailer} = assign(c, next.assignment)
    end

    {:ok, _} = Employment.end_shop_assignment(c.assignment, Date.utc_today())
    assert {:error, :ineligible_detailer} = assign(c)
  end

  test "one active shift must cover service AND buffer; cancelled, short or unrelated shifts do not",
       c do
    assert {:ok, _} = WorkSchedules.cancel_shift(c.credential, ref(c))
    assert {:error, :missing_covering_shift} = assign(c)

    {:ok, short} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: c.booking.starts_at,
        ends_at: DateTime.add(c.booking.starts_at, 60 * 60)
      })

    assert {:error, :missing_covering_shift} = assign(c)
    {:ok, _} = WorkSchedules.cancel_shift(c.credential, %WorkShift{id: short.id})

    {:ok, exact} =
      WorkSchedules.create_shift(c.credential, c.assignment, %{
        starts_at: c.booking.starts_at,
        ends_at: DateTime.add(c.booking.starts_at, 90 * 60)
      })

    assert {:ok, j} = assign(c)
    assert j.work_shift_id == exact.id

    assert {:error, :assigned_jobs} =
             WorkSchedules.cancel_shift(c.credential, %WorkShift{id: exact.id})

    assert {:error, :assigned_jobs} =
             WorkSchedules.reschedule_shift(c.credential, %WorkShift{id: exact.id}, %{
               starts_at: DateTime.add(c.booking.starts_at, 3600),
               ends_at: DateTime.add(c.booking.starts_at, 7200)
             })

    assert Repo.get!(WorkShift, exact.id).status == :active
    {:ok, _} = JobAssignments.unassign(c.credential, c.booking)
    assert {:ok, _} = WorkSchedules.cancel_shift(c.credential, %WorkShift{id: exact.id})
  end

  test "own work requires exact linked identity, active Employee scope and current assignment",
       c do
    {:ok, j} = assign(c)
    assert {:ok, %{assignments: [^j]}} = JobAssignments.list_own_work(c.detailer, c.business)

    assert :ok =
             Authorization.authorize(c.detailer, :jobs_assigned_read, %JobAssignment{id: j.id})

    assert {:error, :forbidden} = JobAssignments.list_own_work(c.owner, c.business)
    other = active_user_fixture()
    grant_fixture(other, c.shop, :employee)
    assert {:error, :forbidden} = JobAssignments.list_own_work(other, c.business)
    {:ok, _} = Memberships.revoke(c.employee_membership)
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)
    assert Repo.get!(JobAssignment, j.id).status == :active
  end

  test "revoked sessions, suspended actors and archived tenants fail immediately", c do
    assert {:error, :forbidden} = JobAssignments.assign(c.owner, c.booking, c.assignment)
    assert {:error, :forbidden} = JobAssignments.assign(%{}, c.booking, c.assignment)
    {:ok, _} = Accounts.revoke_session(c.session, :logout)
    assert {:error, :forbidden} = assign(c)

    Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
      set: [status: :suspended]
    )

    assert {:error, :forbidden} = JobAssignments.list_shop_assignments(c.owner, c.shop)
  end

  test "archived business or shop and revoked grants cannot authorize assignments", c do
    Repo.update_all(from(s in Shop, where: s.id == ^c.shop.id), set: [status: :archived])
    assert {:error, :forbidden} = assign(c)
    Repo.update_all(from(s in Shop, where: s.id == ^c.shop.id), set: [status: :active])
    Repo.update_all(from(b in Business, where: b.id == ^c.business.id), set: [status: :archived])
    assert {:error, :forbidden} = assign(c)
    Repo.update_all(from(b in Business, where: b.id == ^c.business.id), set: [status: :active])
    {:ok, _} = Memberships.revoke(c.membership)
    assert {:error, :forbidden} = assign(c)
  end

  test "termination retains shift, booking, job and audit; authorized manager can explicitly unassign",
       c do
    {:ok, j} = assign(c)
    assert {:ok, _} = Employment.end_employment(c.employment, Date.utc_today())
    assert Repo.get!(WorkShift, c.shift.id).status == :active
    assert Repo.get!(Appointment, c.booking.id)
    assert Repo.get!(JobAssignment, j.id).status == :active
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 1
    assert {:error, :forbidden} = JobAssignments.list_own_work(c.detailer, c.business)
    assert {:ok, %{assignments: [item]}} = JobAssignments.list_shop_assignments(c.owner, c.shop)
    assert item.id == j.id
    assert {:ok, _} = JobAssignments.unassign(c.credential, c.booking)
    assert {:error, :ineligible_detailer} = assign(c)
  end

  test "cross-shop employee conflict includes buffer and nonoverlapping jobs in another shop succeed",
       c do
    {:ok, _} = assign(c)
    %{shop: shop, price: price} = shop_price_fixture(c.price)
    {:ok, a} = Employment.assign_shop(c.employment, shop, %{starts_on: ~D[2026-01-01]})
    attrs = %{booking_attrs(price) | starts_at: DateTime.add(c.booking.starts_at, 60 * 60)}
    {:ok, conflict} = Appointments.create_appointment(shop, attrs)
    assert {:error, :overlap} = JobAssignments.assign(c.credential, conflict, a)
    # Next-day covering shift in the other shop is valid and independent.
    {:ok, start} = WorkShift.instant(c.booking.starts_at)
    date = start |> Availability.local_datetime() |> NaiveDateTime.to_date() |> Date.add(2)
    date = if Date.day_of_week(date) == 7, do: Date.add(date, 1), else: date
    {:ok, nextbooking} = Appointments.create_appointment(shop, booking_attrs(price, date))

    {:ok, _} =
      WorkSchedules.create_shift(c.credential, a, %{
        starts_at: nextbooking.starts_at,
        ends_at: DateTime.add(nextbooking.starts_at, 4 * 3600)
      })

    assert {:ok, _} = JobAssignments.assign(c.credential, nextbooking, a)
  end

  test "assignment does not alter public availability, booking constraints, prices or duration",
       c do
    date = c.booking.starts_at |> Availability.local_datetime() |> NaiveDateTime.to_date()

    before =
      Availability.get_for_shop(c.shop, date, c.price.id)

    {:ok, _} = assign(c)

    assert before ==
             Availability.get_for_shop(c.shop, date, c.price.id)

    assert Repo.reload!(c.booking) == c.booking
    assert {:error, _} = Appointments.create_appointment(c.shop, booking_attrs(c.price))
  end

  test "scoped pagination keeps foreign jobs out of items and cursors", c do
    {:ok, j} = assign(c)
    next = second_detailer(c)

    {:ok, booking2} =
      Appointments.create_appointment(c.shop, %{
        booking_attrs(c.price)
        | starts_at: DateTime.add(c.booking.starts_at, 2 * 3600)
      })

    {:ok, j2} = JobAssignments.assign(c.credential, booking2, next.assignment)
    foreign = job_fixture()
    {:ok, _} = assign(foreign)

    assert {:ok, %{assignments: [^j], has_more: true, next_cursor: cursor}} =
             JobAssignments.list_shop_assignments(c.owner, c.shop, limit: 1)

    assert {:ok, %{assignments: [^j2], has_more: false, next_cursor: nil}} =
             JobAssignments.list_shop_assignments(c.owner, c.shop, limit: 1, cursor: cursor)

    assert {:ok, %{assignments: [^j]}} = JobAssignments.list_own_work(c.detailer, c.business)

    assert {:error, :invalid_options} =
             JobAssignments.list_shop_assignments(c.owner, c.shop, cursor: "bad")

    assert {:error, :invalid_options} =
             JobAssignments.list_shop_assignments(c.owner, c.shop, limit: 101)
  end

  test "inactive or unverified actors and revoked grants cannot read or mutate jobs", c do
    {:ok, _} = assign(c)

    for status <- [:pending, :suspended, :deactivated] do
      Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
        set: [status: status]
      )

      assert {:error, :forbidden} = JobAssignments.unassign(c.credential, c.booking)
      assert {:error, :forbidden} = JobAssignments.list_shop_assignments(c.owner, c.shop)
    end

    Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
      set: [status: :active, email_verified: false]
    )

    assert {:error, :forbidden} = JobAssignments.unassign(c.credential, c.booking)

    Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
      set: [email_verified: true]
    )

    Repo.update!(
      Ecto.Changeset.change(c.grant,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = JobAssignments.unassign(c.credential, c.booking)
    assert {:error, :forbidden} = JobAssignments.list_shop_assignments(c.owner, c.shop)
  end

  test "unlinked active Detailers can work but cannot gain own-read through classification alone",
       c do
    next = second_detailer(c)
    assert is_nil(next.employment.user_id)
    assert {:ok, _} = assign(c, next.assignment)
    assert {:ok, %{assignments: []}} = JobAssignments.list_own_work(c.detailer, c.business)
    {:ok, _} = JobAssignments.unassign(c.credential, c.booking)
    # Future-effective assignment cannot cover this job; an Employee grant cannot
    # alter a management classification or bypass missing eligibility/coverage.
    e =
      SchedulerApi.EmploymentFixtures.employment_fixture(%{starts_on: ~D[2099-01-01]},
        business: c.business
      )

    {:ok, a} = Employment.assign_shop(e, c.shop, %{starts_on: ~D[2099-01-01]})
    assert {:error, :ineligible_detailer} = assign(c, a)
  end

  test "cancelled and completed appointments cannot receive jobs; denial is audited", c do
    for status <- [:cancelled, :completed] do
      Repo.update_all(from(a in Appointment, where: a.id == ^c.booking.id), set: [status: status])
      assert {:error, :invalid_appointment} = assign(c)
    end

    assert Repo.aggregate(JobAssignment, :count) == 0
    assert Repo.aggregate(JobAssignmentAuditEvent, :count) == 2
  end
end
