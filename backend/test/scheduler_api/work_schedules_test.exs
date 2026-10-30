defmodule SchedulerApi.WorkSchedulesTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.WorkShiftFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Authorization, Employment}
  alias SchedulerApi.Employment.{WorkSchedules, WorkShift, WorkShiftAuditEvent}
  alias SchedulerApi.Organizations.Memberships

  @now ~U[2026-10-30 12:00:00Z]
  @attrs %{starts_at: ~U[2026-11-02 16:00:00Z], ends_at: ~U[2026-11-02 19:00:00Z]}
  @keys [
    :id,
    :assignment_id,
    :employment_id,
    :business_id,
    :shop_id,
    :starts_at,
    :ends_at,
    :timezone,
    :status,
    :supersedes_id,
    :closed_at
  ]
  setup do: work_shift_fixture()

  defp create(c, attrs \\ @attrs, assignment \\ nil),
    do: WorkSchedules.create_shift(c.credential, assignment || c.assignment, attrs, now: @now)

  defp cancel(c, shift), do: WorkSchedules.cancel_shift(c.credential, shift, now: @now)

  defp move(c, shift, attrs),
    do: WorkSchedules.reschedule_shift(c.credential, shift, attrs, now: @now)

  defp shift_ref(dto), do: %WorkShift{id: dto.id}

  defp reject(sql, params, code) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Repo.query(sql, params, mode: :savepoint)
  end

  test "Owner creates explicit UTC shifts, scoped projections and atomic audit", c do
    assert {:ok, shift} =
             create(c, %{
               starts_at: "2026-11-02T09:00:00-07:00",
               ends_at: "2026-11-02T12:00:00-07:00"
             })

    assert shift.starts_at == @attrs.starts_at and shift.ends_at == @attrs.ends_at
    assert shift.timezone == c.shop.timezone and shift.status == :active
    assert Enum.sort(Map.keys(shift)) == Enum.sort(@keys)
    assert {:ok, dto} = WorkSchedules.get_shift(c.owner, shift_ref(shift))
    assert dto == shift
    assert {:ok, page} = WorkSchedules.list_shop_shifts(c.owner, c.shop)
    assert page.shifts == [dto] and not page.has_more
    event = Repo.one!(WorkShiftAuditEvent)

    assert {event.actor_user_id, event.business_id, event.shop_id, event.assignment_id,
            event.shift_id, event.action, event.outcome} ==
             {c.owner.id, c.business.id, c.shop.id, c.assignment.id, shift.id, :create, :applied}

    assert :ok = Authorization.authorize(c.owner, :schedule_manage, shift_ref(shift))
  end

  test "overlap blocks across shops for one employment; adjacency and different employees are allowed",
       c do
    {:ok, first} = create(c)
    shop2 = shop_fixture(%{business_id: c.business.id})
    {:ok, a2} = Employment.assign_shop(c.employment, shop2, %{starts_on: ~D[2026-01-01]})

    assert {:error, :overlap} =
             create(
               c,
               %{starts_at: ~U[2026-11-02 17:00:00Z], ends_at: ~U[2026-11-02 20:00:00Z]},
               a2
             )

    assert {:ok, _} =
             create(
               c,
               %{starts_at: first.ends_at, ends_at: DateTime.add(first.ends_at, 3600)},
               a2
             )

    colleague = employment_fixture(%{}, business: c.business)
    {:ok, another} = Employment.assign_shop(colleague, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, _} = create(c, @attrs, another)
  end

  test "rescheduling supersedes immutable boundaries and cancellation releases only the active period",
       c do
    {:ok, original} = create(c)
    attrs = %{starts_at: ~U[2026-11-02 17:00:00Z], ends_at: ~U[2026-11-02 20:00:00Z]}
    assert {:ok, replacement} = move(c, shift_ref(original), attrs)
    stored = Repo.get!(WorkShift, original.id)

    assert stored.starts_at == original.starts_at and stored.ends_at == original.ends_at and
             stored.status == :superseded

    assert replacement.supersedes_id == original.id and replacement.id != original.id
    assert {:error, :not_active} = move(c, shift_ref(original), @attrs)
    assert {:ok, closed} = cancel(c, shift_ref(replacement))
    assert closed.status == :cancelled and closed.closed_at == @now
    assert {:error, :not_active} = cancel(c, shift_ref(replacement))
    assert {:ok, _} = create(c)
    assert {:ok, history} = WorkSchedules.list_shop_shifts(c.owner, c.shop)
    assert length(history.shifts) == 3
    assert Enum.all?(history.shifts, &(Enum.sort(Map.keys(&1)) == Enum.sort(@keys)))
    assert Enum.count(Repo.all(WorkShiftAuditEvent), &(&1.outcome == :applied)) == 4
  end

  test "overlapping/unchanged replacements leave the original active and audit the rejection",
       c do
    {:ok, original} = create(c)

    {:ok, _} =
      create(c, %{starts_at: ~U[2026-11-02 20:00:00Z], ends_at: ~U[2026-11-02 22:00:00Z]})

    assert {:error, :overlap} =
             move(c, shift_ref(original), %{
               starts_at: @attrs.starts_at,
               ends_at: ~U[2026-11-02 21:00:00Z]
             })

    assert {:error, :unchanged} = move(c, shift_ref(original), @attrs)
    assert Repo.get!(WorkShift, original.id).status == :active
    assert Repo.aggregate(WorkShift, :count) == 2
  end

  test "Shop Managers act only in explicitly granted shops; HR and Employee roles cannot supply missing scope",
       c do
    actor = active_user_fixture()
    grant_fixture(actor, c.shop, :shop_manager)
    {:ok, _, credential} = Accounts.create_session(actor)
    assert {:ok, own} = WorkSchedules.create_shift(credential, c.assignment, @attrs, now: @now)
    shop2 = shop_fixture(%{business_id: c.business.id})
    {:ok, other} = Employment.assign_shop(c.employment, shop2, %{starts_on: ~D[2026-01-01]})
    grant_fixture(actor, shop2, :employee)
    foreign = work_shift_fixture()
    grant_fixture(actor, foreign.shop, :business_manager)
    shifted = %{starts_at: ~U[2026-11-03 16:00:00Z], ends_at: ~U[2026-11-03 19:00:00Z]}

    assert {:error, :forbidden} =
             WorkSchedules.create_shift(credential, other, shifted, now: @now)

    assert {:error, :forbidden} =
             WorkSchedules.create_shift(credential, foreign.assignment, shifted, now: @now)

    assert {:error, :forbidden} = WorkSchedules.list_shop_shifts(actor, shop2)
    assert {:error, :forbidden} = WorkSchedules.list_shop_shifts(actor, foreign.shop)
    assert {:ok, _} = WorkSchedules.cancel_shift(credential, shift_ref(own), now: @now)

    for role <- [:business_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      {:ok, _, token} = Accounts.create_session(user)

      assert {:error, :forbidden} =
               WorkSchedules.create_shift(token, c.assignment, shifted, now: @now)
    end
  end

  test "Employee sees only explicit own linked shifts; management classification never grants scheduling authority",
       c do
    employee = active_user_fixture()
    grant_fixture(employee, c.shop, :employee)
    assert {:error, :forbidden} = WorkSchedules.list_own_shifts(employee, c.business)

    record =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: employee)

    {:ok, a} = Employment.assign_shop(record, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, own} = create(c, @attrs, a)
    {:ok, other} = create(c)
    assert {:ok, page} = WorkSchedules.list_own_shifts(employee, c.business)
    assert Enum.map(page.shifts, & &1.id) == [own.id]
    assert {:ok, _} = WorkSchedules.get_shift(employee, shift_ref(own))

    assert {:error, :forbidden} =
             WorkSchedules.get_shift(employee, %{shift_ref(other) | employment_id: record.id})

    assert {:error, :forbidden} = WorkSchedules.list_shop_shifts(employee, c.shop)
    {:ok, _, token} = Accounts.create_session(employee)
    assert {:error, :forbidden} = WorkSchedules.cancel_shift(token, shift_ref(own), now: @now)
    assert {:error, :forbidden} = WorkSchedules.create_shift(token, a, @attrs, now: @now)
    assert Repo.reload!(record).classification == :business_owner
    Repo.update!(change(employee, email_verified: false))
    assert {:error, :forbidden} = WorkSchedules.list_own_shifts(employee, c.business)
    assert {:error, :forbidden} = WorkSchedules.get_shift(employee, shift_ref(own))
    Repo.update!(change(employee, email_verified: true))
    assert {:ok, _} = Employment.end_shop_assignment(a, ~D[2026-11-03])
    assert {:error, :forbidden} = WorkSchedules.list_own_shifts(employee, c.business)
    assert {:error, :forbidden} = WorkSchedules.get_shift(employee, shift_ref(own))
  end

  test "one linked person reads each business only through its own matching role and assignment",
       c do
    employee = active_user_fixture()
    grant_fixture(employee, c.shop, :employee)
    own = employment_fixture(%{}, business: c.business, user: employee)
    {:ok, a} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, first} = create(c, @attrs, a)
    foreign = work_shift_fixture()
    grant_fixture(employee, foreign.shop, :employee)
    assert {:error, :forbidden} = WorkSchedules.list_own_shifts(employee, foreign.business)
    other = employment_fixture(%{}, business: foreign.business, user: employee)
    {:ok, b} = Employment.assign_shop(other, foreign.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, second} = create(foreign, @attrs, b)
    {:ok, unrelated} = create(foreign)
    assert {:ok, home} = WorkSchedules.list_own_shifts(employee, c.business)
    assert Enum.map(home.shifts, & &1.id) == [first.id]
    assert {:ok, away} = WorkSchedules.list_own_shifts(employee, foreign.business)
    assert Enum.map(away.shifts, & &1.id) == [second.id]
    assert {:error, :forbidden} = WorkSchedules.get_shift(employee, shift_ref(unrelated))
  end

  test "employment and assignment dates are interpreted in the persisted shop timezone", c do
    shop = shop_fixture(%{business_id: c.business.id, timezone: "Pacific/Honolulu"})
    {:ok, assignment} = Employment.assign_shop(c.employment, shop, %{starts_on: ~D[2026-10-31]})

    assert {:error, :ineligible_assignment} =
             create(
               c,
               %{starts_at: ~U[2026-10-31 08:00:00Z], ends_at: ~U[2026-10-31 09:00:00Z]},
               assignment
             )

    assert {:ok, shift} =
             create(
               c,
               %{starts_at: ~U[2026-10-31 10:00:00Z], ends_at: ~U[2026-11-01 10:00:00Z]},
               assignment
             )

    assert shift.timezone == "Pacific/Honolulu"
    assert {:ok, _} = Employment.end_shop_assignment(assignment, ~D[2026-11-02])

    assert {:error, :ineligible_assignment} =
             create(
               c,
               %{starts_at: ~U[2026-11-03 10:00:00Z], ends_at: ~U[2026-11-03 11:00:00Z]},
               assignment
             )
  end

  test "DST gap is rejected and both fold instants are explicit, distinct and stored in UTC", c do
    local = ~N[2026-11-01 01:15:00]

    assert {:ok, early} =
             WorkSchedules.local_to_utc(%{c.shop | timezone: "Etc/UTC"}, local, -21600)

    assert {:ok, late} = WorkSchedules.local_to_utc(c.shop, local, -25200)
    assert early == ~U[2026-11-01 07:15:00Z] and DateTime.diff(late, early) == 3600

    for offset <- [-21600, -25200] do
      assert {:error, :invalid_local_time} =
               WorkSchedules.local_to_utc(c.shop, ~N[2026-03-08 02:30:00], offset)
    end

    assert {:error, :invalid_local_time} = WorkSchedules.local_to_utc(c.shop, local, 0)

    for start <- [early, late] do
      assert {:ok, _} = create(c, %{starts_at: start, ends_at: DateTime.add(start, 1800)})
    end

    assert {:error, :invalid_input} =
             create(c, %{starts_at: local, ends_at: ~N[2026-11-01 02:00:00]})

    Repo.update!(change(c.shop, timezone: "not-a-timezone"))
    assert {:error, :invalid_timezone} = WorkSchedules.local_to_utc(c.shop, local, -21600)
  end

  test "termination retains shifts, assignments and audits, blocks new work, and permits audited cancellation",
       c do
    {:ok, shift} = create(c)
    before = Repo.aggregate(WorkShiftAuditEvent, :count)
    {:ok, ended} = Employment.end_employment(c.employment, ~D[2026-10-31])
    assert Repo.get!(WorkShift, shift.id).status == :active
    assert Repo.reload!(c.assignment).status == :ended and Repo.reload!(ended).status == :ended
    assert Repo.aggregate(WorkShiftAuditEvent, :count) == before
    assert {:error, :ineligible_assignment} = create(c)

    assert {:error, :ineligible_assignment} =
             move(c, shift_ref(shift), %{
               starts_at: ~U[2026-11-03 16:00:00Z],
               ends_at: ~U[2026-11-03 19:00:00Z]
             })

    assert {:ok, page} = WorkSchedules.list_shop_shifts(c.owner, c.shop)
    assert Enum.map(page.shifts, & &1.id) == [shift.id]
    assert {:ok, _} = cancel(c, shift_ref(shift))

    for {table, id} <- [
          {"employments", ended.id},
          {"employment_shop_assignments", c.assignment.id},
          {"work_shifts", shift.id}
        ] do
      reject("DELETE FROM #{table} WHERE id=$1", [id], :restrict_violation)
    end
  end

  test "spoofed refs, credential claims, status and ownership fields never authorize or change scope",
       c do
    foreign = work_shift_fixture()

    assert {:error, :forbidden} =
             create(c, @attrs, %{
               foreign.assignment
               | business_id: c.business.id,
                 shop_id: c.shop.id,
                 employment_id: c.employment.id
             })

    for actor <- [c.owner, %{id: c.owner.id}, nil] do
      assert {:error, :forbidden} =
               WorkSchedules.create_shift(actor, c.assignment, @attrs, now: @now)
    end

    for attrs <- [
          Map.put(@attrs, :shop_id, foreign.shop.id),
          Map.put(@attrs, :status, :cancelled),
          Map.put(@attrs, :timezone, "Etc/UTC"),
          %{starts_at: @attrs.ends_at, ends_at: @attrs.starts_at},
          %{starts_at: @attrs.starts_at, ends_at: @attrs.starts_at},
          %{starts_at: "2026-11-02T09:00:00", ends_at: @attrs.ends_at}
        ] do
      assert {:error, :invalid_input} = create(c, attrs)
    end

    assert Repo.aggregate(WorkShift, :count) == 0
  end

  test "revocations and archived shops/businesses are rechecked, including stale structs", c do
    {:ok, shift} = create(c)
    query = Authorization.authorized_work_shift_ids_query(c.owner, :schedule_manage)
    assert Repo.all(query) != []
    {:ok, _} = Accounts.revoke_session(c.session, :logout)
    assert {:error, :forbidden} = cancel(c, shift_ref(shift))
    {:ok, _, fresh} = Accounts.create_session(c.owner)
    {:ok, _} = Memberships.revoke(c.membership)
    assert Repo.all(query) == []
    assert {:error, :forbidden} = WorkSchedules.cancel_shift(fresh, shift_ref(shift), now: @now)
    {:ok, _} = Memberships.reactivate(c.membership)
    assert {:error, :forbidden} = WorkSchedules.get_shift(c.owner, shift_ref(shift))
    grant_fixture(c.owner, c.shop, :business_owner)
    Repo.update!(change(c.shop, status: :archived))
    assert {:error, :forbidden} = WorkSchedules.list_shop_shifts(c.owner, c.shop)
    Repo.update!(change(c.shop, status: :active))
    Repo.update!(change(c.business, status: :archived))
    assert {:error, :forbidden} = WorkSchedules.get_shift(c.owner, shift_ref(shift))
  end

  test "pending suspended deactivated and unverified actors cannot manage or read schedules", c do
    {:ok, shift} = create(c)

    for status <- [:pending, :suspended, :deactivated, :unverified] do
      actor = active_user_fixture()
      grant_fixture(actor, c.shop, :business_owner)
      {:ok, _, credential} = Accounts.create_session(actor)

      if status == :unverified,
        do: Repo.update!(change(actor, email_verified: false)),
        else: Accounts.set_user_status(actor, status)

      assert {:error, :forbidden} =
               WorkSchedules.cancel_shift(credential, shift_ref(shift), now: @now)

      assert {:error, :forbidden} = WorkSchedules.get_shift(actor, shift_ref(shift))
    end
  end

  test "SQL scoping, duplicate grants, ordering, windows and cursors cannot leak other shops",
       c do
    grant_fixture(c.owner, c.shop, :shop_manager)
    {:ok, first} = create(c)
    foreign = work_shift_fixture()
    {:ok, foreign_shift} = create(foreign)
    later = %{starts_at: ~U[2026-11-03 16:00:00Z], ends_at: ~U[2026-11-03 19:00:00Z]}
    {:ok, second} = create(c, later)
    assert {:ok, p1} = WorkSchedules.list_shop_shifts(c.owner, c.shop, limit: 1)
    assert Enum.map(p1.shifts, & &1.id) == [first.id] and p1.has_more

    assert {:ok, p2} =
             WorkSchedules.list_shop_shifts(c.owner, c.shop, limit: 1, cursor: p1.next_cursor)

    assert Enum.map(p2.shifts, & &1.id) == [second.id] and not p2.has_more

    forged =
      Base.url_encode64(
        Jason.encode!([1, DateTime.to_iso8601(foreign_shift.starts_at), foreign_shift.id]),
        padding: false
      )

    assert {:ok, page} = WorkSchedules.list_shop_shifts(c.owner, c.shop, cursor: forged)
    refute Enum.any?(page.shifts, &(&1.id == foreign_shift.id))

    assert {:ok, window} =
             WorkSchedules.list_shop_shifts(c.owner, c.shop,
               from: @attrs.ends_at,
               until: later.ends_at
             )

    assert Enum.map(window.shifts, & &1.id) == [second.id]

    for opts <- [
          [limit: 101],
          [limit: 0],
          [cursor: "bad"],
          [from: "naive"],
          [shop_id: foreign.shop.id],
          [from: later.ends_at, until: later.starts_at]
        ] do
      assert {:error, :invalid_options} = WorkSchedules.list_shop_shifts(c.owner, c.shop, opts)
    end
  end

  test "database enforces composite ownership, active overlap, eligibility and immutable history",
       c do
    sql =
      "INSERT INTO work_shifts(assignment_id,employment_id,business_id,shop_id,starts_at,ends_at,timezone,inserted_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)"

    params = [
      c.assignment.id,
      c.employment.id,
      c.business.id,
      c.shop.id,
      DateTime.to_naive(@attrs.starts_at),
      DateTime.to_naive(@attrs.ends_at),
      c.shop.timezone,
      DateTime.to_naive(@now)
    ]

    foreign = work_shift_fixture()
    reject(sql, List.replace_at(params, 2, foreign.business.id), :foreign_key_violation)
    reject(sql, List.replace_at(params, 3, foreign.shop.id), :foreign_key_violation)
    reject(sql, List.replace_at(params, 5, DateTime.to_naive(@attrs.starts_at)), :check_violation)
    {:ok, shift} = create(c)
    reject(sql, params, :exclusion_violation)

    reject(
      "UPDATE work_shifts SET ends_at=ends_at+interval '1 hour' WHERE id=$1",
      [shift.id],
      :check_violation
    )

    {:ok, _} = cancel(c, shift_ref(shift))

    reject(
      "UPDATE work_shifts SET status='active',closed_at=NULL WHERE id=$1",
      [shift.id],
      :check_violation
    )

    {:ok, _} = Employment.end_shop_assignment(c.assignment, ~D[2026-11-03])
    reject(sql, params, :check_violation)
  end

  test "work shifts do not change appointment availability, buffers or shared-shop booking capacity",
       c do
    alias SchedulerApi.Catalog.{Service, VehicleSize}

    service =
      Repo.insert!(%Service{
        business_id: c.business.id,
        name: "Shift-independent",
        description: "Test"
      })

    size = Repo.insert!(%VehicleSize{business_id: c.business.id, name: "Small", sort_order: 1})

    {:ok, price} =
      SchedulerApi.Catalog.create_service_price(c.shop, %{
        service_id: service.id,
        vehicle_size_id: size.id,
        price_cents: 5000,
        duration_minutes: 60
      })

    attrs = SchedulerApi.AppointmentsFixtures.booking_attrs(price)
    {:ok, start} = WorkShift.instant(attrs.starts_at)
    date = SchedulerApi.AppointmentsFixtures.booking_date() |> Date.to_iso8601()
    {:ok, before} = SchedulerApi.Appointments.Availability.get_for_shop(c.shop, date, price.id)
    {:ok, _} = create(c, %{starts_at: start, ends_at: DateTime.add(start, 3600)})

    assert {:ok, ^before} =
             SchedulerApi.Appointments.Availability.get_for_shop(c.shop, date, price.id)

    assert {:ok, _} = SchedulerApi.Appointments.create_appointment(c.shop, attrs)
  end
end
