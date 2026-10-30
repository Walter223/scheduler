defmodule SchedulerApi.EmploymentHRTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.CompensationFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.{Accounts, Employment, Authorization}

  alias SchedulerApi.Employment.{
    HR,
    EmploymentRecord,
    ShopAssignment,
    HrAuditEvent,
    ClassificationHistory,
    Compensation,
    WorkSchedules,
    WorkShift
  }

  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment}
  alias SchedulerApi.Organizations.{Memberships, Shop, Business}
  setup do: compensation_fixture()

  defp attrs,
    do: %{
      first_name: " Alex ",
      last_name: "Worker",
      classification: :detailer,
      starts_on: ~D[2026-01-01]
    }

  test "Owner creates an unlinked employee with trimmed business-specific contact fields and atomic history",
       c do
    input =
      Map.merge(attrs(), %{
        phone: " 303-555-0100 ",
        email: " alex@example.com ",
        home_address: " 123 Test Way "
      })

    assert {:ok, e} = HR.create_employment(c.credential, c.business, input)

    assert e.business_id == c.business.id and e.first_name == "Alex" and
             e.home_address == "123 Test Way"

    assert Repo.get!(EmploymentRecord, e.id).user_id == nil
    assert Repo.aggregate(SchedulerApi.Accounts.User, :count) == 1
    assert Repo.aggregate(SchedulerApi.Organizations.RoleAssignment, :count) == 1
    history = Repo.one!(from h in ClassificationHistory, where: h.employment_id == ^e.id)
    event = Repo.one!(HrAuditEvent)
    assert history.source == :created and history.classification == :detailer
    assert event.actor_user_id == c.owner.id and event.classification_history_id == history.id
    assert event.action == :create and event.outcome == :applied

    for field <- [:user_id, :password, :token, :compensation, :bank_account, :ssn],
        do: refute(Map.has_key?(e, field))
  end

  test "Business Manager can create, edit contact, classify, assign and end a shop assignment",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {:ok, _, token} = Accounts.create_session(manager)
    assert {:ok, e} = HR.create_employment(token, c.business, attrs())
    ref = %EmploymentRecord{id: e.id, business_id: -1}

    assert {:ok, contact} =
             HR.update_contact(token, ref, %{
               "first_name" => "Jamie",
               "phone" => "555",
               "email" => "jamie@example.com",
               "home_address" => "Test address"
             })

    assert contact.first_name == "Jamie"
    assert {:ok, e} = HR.change_classification(token, ref, :shop_manager)
    assert e.classification == :shop_manager
    assert {:ok, a} = HR.assign_shop(token, ref, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, ended} = HR.end_shop_assignment(token, %ShopAssignment{id: a.id}, ~D[2026-10-30])
    assert ended.status == :ended and Repo.get!(EmploymentRecord, e.id).status == :active
    assert {:ok, new} = HR.assign_shop(token, ref, c.shop, %{starts_on: ~D[2026-10-31]})
    assert new.id != a.id
    assert Repo.get!(ShopAssignment, a.id).status == :ended
    assert Repo.aggregate(HrAuditEvent, :count) == 6
  end

  test "Shop Managers and Employees cannot mutate HR even at assigned shops", c do
    {:ok, a} = Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

    for role <- [:shop_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      {:ok, _, token} = Accounts.create_session(user)
      assert {:error, :forbidden} = HR.create_employment(token, c.business, attrs())
      assert {:error, :forbidden} = HR.update_contact(token, c.employment, %{phone: "spoofed"})
      assert {:error, :forbidden} = HR.change_classification(token, c.employment, :business_owner)

      assert {:error, :forbidden} =
               HR.assign_shop(token, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

      assert {:error, :forbidden} = HR.end_shop_assignment(token, a, ~D[2026-10-30])
    end

    assert Repo.reload!(c.employment).classification == :detailer
    assert Repo.reload!(a).status == :active
  end

  test "contact and creation allowlists reject ownership, identity, status, pay and arbitrary fields",
       c do
    for field <- [
          :business_id,
          :user_id,
          :status,
          :classification,
          :starts_on,
          :amount,
          :bank_account,
          :ssn,
          :unknown
        ] do
      assert {:error, :invalid_input} =
               HR.update_contact(c.credential, c.employment, %{field => "spoof"})
    end

    for field <- [:user_id, :business_id, :status, :role] do
      assert {:error, :invalid_input} =
               HR.create_employment(c.credential, c.business, Map.put(attrs(), field, 1))
    end

    assert {:error, :invalid_input} =
             HR.update_contact(c.credential, c.employment, %{:phone => "a", "phone" => "b"})

    assert {:error, :invalid_input} =
             HR.update_contact(c.credential, c.employment, %{first_name: "   "})

    assert {:error, :invalid_input} =
             HR.update_contact(c.credential, c.employment, %{email: "invalid"})

    assert {:error, :invalid_input} =
             HR.update_contact(c.credential, c.employment, %{
               home_address: String.duplicate("a", 1001)
             })

    assert {:error, :unchanged} = HR.update_contact(c.credential, c.employment, %{})

    assert {:ok, e} =
             HR.update_contact(c.credential, c.employment, %{
               phone: "  ",
               email: nil,
               home_address: " a "
             })

    assert e.phone == nil and e.email == nil and e.home_address == "a"
  end

  test "persisted tenant ownership wins over spoofed structs and never combines foreign grants",
       c do
    foreign = compensation_fixture()

    assert {:error, :forbidden} =
             HR.update_contact(
               c.credential,
               %{foreign.employment | business_id: c.business.id},
               %{phone: "x"}
             )

    assert {:error, :invalid_shop} =
             HR.assign_shop(
               c.credential,
               c.employment,
               %{foreign.shop | business_id: c.business.id},
               %{starts_on: ~D[2026-01-01]}
             )

    user = active_user_fixture()
    grant_fixture(user, c.shop, :shop_manager)
    grant_fixture(user, foreign.shop, :business_owner)
    {:ok, _, token} = Accounts.create_session(user)
    assert {:error, :forbidden} = HR.change_classification(token, c.employment, :detailer)
    assert {:error, :forbidden} = HR.create_employment(c.credential, foreign.business, attrs())
    assert Repo.reload!(foreign.employment).phone == nil
  end

  test "classification changes are append-only, fixed and never grant access", c do
    assert {:error, :invalid_input} =
             HR.change_classification(c.credential, c.employment, :employee)

    assert {:error, :invalid_input} =
             HR.change_classification(c.credential, c.employment, :god_mode)

    assert {:error, :unchanged} = HR.change_classification(c.credential, c.employment, :detailer)
    assert {:ok, _} = HR.change_classification(c.credential, c.employment, "shop_manager")
    assert {:ok, _} = HR.change_classification(c.credential, c.employment, :detailer)

    rows =
      Repo.all(
        from h in ClassificationHistory,
          where: h.employment_id == ^c.employment.id,
          order_by: h.id
      )

    assert Enum.map(rows, &{&1.previous_classification, &1.classification}) == [
             {nil, :detailer},
             {:detailer, :shop_manager},
             {:shop_manager, :detailer}
           ]

    assert Repo.aggregate(SchedulerApi.Organizations.RoleAssignment, :count) == 1

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE employment_classification_history SET classification='detailer' WHERE id=$1",
               [hd(rows).id],
               mode: :savepoint
             )
  end

  test "former Owner pay stays private from HR Managers after reclassification", c do
    {:ok, _} = HR.change_classification(c.credential, c.employment, :business_owner)

    assert {:ok, _} =
             Compensation.set_rate(
               c.credential,
               c.employment,
               %{amount: "100.00", pay_basis: :hourly, effective_from: ~D[2026-10-30]},
               now: ~U[2026-10-30 18:00:00Z]
             )

    {:ok, _} = HR.change_classification(c.credential, c.employment, :detailer)
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)

    assert {:error, :forbidden} =
             Compensation.get_current_rate(manager, c.employment, now: ~U[2026-10-30 18:00:00Z])

    assert {:error, :forbidden} = Compensation.list_rate_history(manager, c.employment)
    {:ok, _, token} = Accounts.create_session(manager)

    assert {:error, :forbidden} =
             Compensation.set_rate(
               token,
               c.employment,
               %{amount: "20.00", pay_basis: :hourly, effective_from: ~D[2026-10-31]},
               now: ~U[2026-10-30 18:00:00Z]
             )

    assert {:ok, [_]} = Compensation.list_rate_history(c.owner, c.employment)
  end

  test "former management pay stays private from Shop Managers, even with linked Employee grants",
       c do
    user = active_user_fixture()
    grant_fixture(user, c.shop, :employee)
    e = employment_fixture(%{classification: :shop_manager}, business: c.business, user: user)
    {:ok, _} = HR.assign_shop(c.credential, e, c.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, _} =
      Compensation.set_rate(
        c.credential,
        e,
        %{amount: "70.00", pay_basis: :hourly, effective_from: ~D[2026-10-30]},
        now: ~U[2026-10-30 18:00:00Z]
      )

    {:ok, _} = HR.change_classification(c.credential, e, :detailer)
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    assert {:error, :forbidden} = Compensation.get_current_rate(sm, e)

    assert {:error, :forbidden} =
             Authorization.authorize(sm, :assigned_employee_compensation_read, e)

    assert {:ok, _} =
             Compensation.get_own_current_rate(user, c.business, now: ~U[2026-10-30 18:00:00Z])
  end

  test "classification and assignment ending reject outstanding shifts and jobs without altering work",
       _ do
    c = job_fixture()

    assert {:error, :outstanding_work} =
             HR.change_classification(c.credential, c.employment, :shop_manager)

    assert {:error, :outstanding_work} =
             HR.end_shop_assignment(c.credential, c.assignment, Date.utc_today())

    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)

    assert {:error, :outstanding_work} =
             HR.change_classification(c.credential, c.employment, :shop_manager)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "employments_outstanding_work"}}} =
             Repo.query(
               "UPDATE employments SET classification='shop_manager' WHERE id=$1",
               [c.employment.id],
               mode: :savepoint
             )

    assert {:error, :outstanding_work} =
             HR.end_shop_assignment(c.credential, c.assignment, Date.utc_today())

    assert Repo.get!(JobAssignment, j.id).status == :active
    assert Repo.get!(WorkShift, c.shift.id).status == :active
    {:ok, _} = JobAssignments.remove_member(c.credential, c.booking, %JobAssignment{id: j.id})
    {:ok, _} = WorkSchedules.cancel_shift(c.credential, %WorkShift{id: c.shift.id})
    assert {:ok, _} = HR.change_classification(c.credential, c.employment, :shop_manager)
    assert {:ok, _} = HR.end_shop_assignment(c.credential, c.assignment, Date.utc_today())
  end

  test "shop lifecycle validates dates, duplicate grants, archived tenants and ended employment",
       c do
    assert {:error, :invalid_date} =
             HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2025-01-01]})

    assert {:ok, a} =
             HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

    assert {:error, :already_assigned} =
             HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

    assert {:error, :invalid_date} =
             HR.end_shop_assignment(c.credential, %ShopAssignment{id: a.id}, ~D[2025-01-01])

    assert {:ok, _} =
             HR.end_shop_assignment(c.credential, %ShopAssignment{id: a.id}, "2026-10-30")

    assert {:error, :assignment_ended} =
             HR.end_shop_assignment(c.credential, %ShopAssignment{id: a.id}, ~D[2026-10-30])

    Repo.update_all(from(s in Shop, where: s.id == ^c.shop.id), set: [status: :archived])

    assert {:error, :invalid_shop} =
             HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-10-31]})

    {:ok, _} = Employment.end_employment(c.employment, ~D[2026-10-30])

    assert {:error, :employment_ended} =
             HR.update_contact(c.credential, c.employment, %{phone: "x"})

    Repo.update_all(from(b in Business, where: b.id == ^c.business.id), set: [status: :archived])
    assert {:error, :forbidden} = HR.create_employment(c.credential, c.business, attrs())
  end

  test "current session, eligibility and revocation are mandatory; audit contains no contact values",
       c do
    assert {:error, :forbidden} = HR.update_contact(c.owner, c.employment, %{phone: "x"})
    assert {:error, :forbidden} = HR.update_contact(nil, c.employment, %{phone: "x"})

    assert {:ok, _} =
             HR.update_contact(
               c.credential,
               c.employment,
               %{phone: "555", home_address: "PRIVATE"},
               now: ~U[2026-10-30 18:00:00Z]
             )

    event = Repo.one!(from a in HrAuditEvent, where: a.outcome == :applied)
    assert Enum.sort(event.changed_fields) == ["home_address", "phone"]
    assert event.occurred_at == ~U[2026-10-30 18:00:00Z]
    refute inspect(event) =~ "PRIVATE"
    {:ok, _} = Memberships.revoke(c.membership)
    assert {:error, :forbidden} = HR.update_contact(c.credential, c.employment, %{phone: "x"})
  end

  test "ineligible accounts, expired/revoked sessions and missing targets fail closed", c do
    for status <- [:pending, :suspended, :deactivated] do
      Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
        set: [status: status]
      )

      assert {:error, :forbidden} = HR.update_contact(c.credential, c.employment, %{phone: "x"})
    end

    Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
      set: [status: :active, email_verified: false]
    )

    assert {:error, :forbidden} = HR.update_contact(c.credential, c.employment, %{phone: "x"})

    Repo.update_all(from(u in SchedulerApi.Accounts.User, where: u.id == ^c.owner.id),
      set: [email_verified: true]
    )

    assert {:error, :forbidden} =
             HR.update_contact(c.credential, %EmploymentRecord{id: -1}, %{phone: "x"})

    assert {:error, :forbidden} = HR.create_employment(c.credential, %Business{id: -1}, attrs())

    assert {:error, :forbidden} =
             HR.end_shop_assignment(c.credential, %ShopAssignment{id: -1}, Date.utc_today())

    {:ok, _} = Accounts.revoke_session(c.session, :logout)
    assert {:error, :forbidden} = HR.update_contact(c.credential, c.employment, %{phone: "x"})

    {:ok, _session, credential} =
      Accounts.create_session(c.owner,
        now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)
      )

    assert {:error, :forbidden} = HR.update_contact(credential, c.employment, %{phone: "x"})
  end
end
