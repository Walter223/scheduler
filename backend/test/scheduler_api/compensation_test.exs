defmodule SchedulerApi.CompensationTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.CompensationFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Authorization, Employment}
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.Employment.{Compensation, CompensationRate, CompensationAuditEvent}
  alias SchedulerApi.Organizations.{Business, Memberships}

  @now ~U[2026-10-29 18:00:00Z]
  @later ~U[2026-11-01 18:00:00Z]
  @attrs %{amount: "25.50", pay_basis: :hourly, effective_from: ~D[2026-10-29]}
  @keys [
    :id,
    :business_id,
    :employment_id,
    :pay_basis,
    :currency,
    :amount,
    :effective_from,
    :effective_until
  ]
  setup do: compensation_fixture()

  defp set(c, target, attrs \\ @attrs, now \\ @now),
    do: Compensation.set_rate(c.credential, target, attrs, now: now)

  defp current(user, target, now \\ @now),
    do: Compensation.get_current_rate(user, target, now: now)

  defp reject(sql, params, code) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Repo.query(sql, params, mode: :savepoint)
  end

  test "exact USD hourly/salary amounts, immutable rate values, half-open boundaries and audit closures",
       c do
    assert {:ok, first} = set(c, c.employment)
    assert first.amount == "25.50" and first.currency == "USD" and first.pay_basis == :hourly
    assert Enum.sort(Map.keys(first)) == Enum.sort(@keys)

    assert {:ok, second} =
             set(c, c.employment, %{
               amount: "85000.00",
               pay_basis: :annual_salary,
               effective_from: ~D[2026-11-01]
             })

    assert {:ok, before} = current(c.owner, c.employment)
    assert before.id == first.id and before.effective_until == ~D[2026-11-01]
    assert {:ok, after_boundary} = current(c.owner, c.employment, @later)
    assert after_boundary.id == second.id and after_boundary.amount == "85000.00"
    assert {:ok, just_before} = current(c.owner, c.employment, ~U[2026-11-01 05:59:59Z])
    assert just_before.id == first.id
    assert {:ok, at_midnight} = current(c.owner, c.employment, ~U[2026-11-01 06:00:00Z])
    assert at_midnight.id == second.id
    assert {:ok, history} = Compensation.list_rate_history(c.owner, c.employment)
    assert Enum.map(history, & &1.id) == [first.id, second.id]
    assert Decimal.equal?(Repo.get!(CompensationRate, first.id).amount, Decimal.new("25.50"))
    events = Repo.all(from a in CompensationAuditEvent, order_by: a.id)
    assert Enum.map(events, & &1.outcome) == [:applied, :applied]
    assert List.last(events).closed_rate_id == first.id
    assert List.last(events).closed_effective_until == second.effective_from

    assert Enum.all?(
             events,
             &(&1.actor_user_id == c.owner.id and &1.business_id == c.business.id and
                 &1.employment_id == c.employment.id)
           )

    refute :amount in CompensationAuditEvent.__schema__(:fields)
    refute :token in CompensationAuditEvent.__schema__(:fields)
    reject("UPDATE compensation_rates SET amount=99 WHERE id=$1", [first.id], :check_violation)

    reject(
      "UPDATE compensation_audit_events SET reason='forbidden' WHERE id=$1",
      [hd(events).id],
      :check_violation
    )
  end

  test "invalid money, floats, currencies, dates and spoofed fields are denied without financial mutations",
       c do
    for amount <- [25.5, 0, -1, "NaN", "Infinity", "25.555", "1e1000000", "1000000000000", nil] do
      assert {:error, :invalid_input} = set(c, c.employment, Map.put(@attrs, :amount, amount))
    end

    for extra <- [
          %{currency: "EUR"},
          %{pay_basis: :commission},
          %{business_id: -1},
          %{employment_id: -1},
          %{actor_user_id: c.owner.id},
          %{ssn: "forbidden"},
          %{"amount" => "30", amount: "20"}
        ] do
      assert {:error, :invalid_input} = set(c, c.employment, Map.merge(@attrs, extra))
    end

    assert {:error, :invalid_effective_date} =
             set(c, c.employment, Map.put(@attrs, :effective_from, ~D[2026-10-28]))

    assert {:error, :invalid_effective_date} =
             set(c, c.employment, Map.put(@attrs, :effective_until, ~D[2026-10-29]))

    assert Repo.aggregate(CompensationRate, :count) == 0
    assert Enum.all?(Repo.all(CompensationAuditEvent), &(&1.outcome == :denied))
    assert {:ok, _} = set(c, c.employment, Map.put(@attrs, :amount, 25))
  end

  test "finite periods allow gaps but reject overlap, same-day replacement and reordered updates",
       c do
    assert {:ok, first} = set(c, c.employment, Map.put(@attrs, :effective_until, ~D[2026-11-02]))
    assert {:error, :effective_date_conflict} = set(c, c.employment)

    assert {:error, :effective_date_conflict} =
             set(c, c.employment, Map.put(@attrs, :effective_from, ~D[2026-11-01]))

    assert {:ok, nil} = current(c.owner, c.employment, ~U[2026-11-02 18:00:00Z])
    assert {:ok, second} = set(c, c.employment, Map.put(@attrs, :effective_from, ~D[2026-11-03]))
    assert {:ok, history} = Compensation.list_rate_history(c.owner, c.employment)
    assert Enum.map(history, & &1.id) == [first.id, second.id]
  end

  test "Business Manager manages employees but never Owner classification or same-business Owner role history",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {:ok, _, credential} = Accounts.create_session(manager)
    assert {:ok, _} = Compensation.set_rate(credential, c.employment, @attrs, now: @now)
    assert {:ok, _} = current(manager, c.employment)
    owner_pay = employment_fixture(%{classification: :business_owner}, business: c.business)
    assert {:ok, _} = set(c, owner_pay)
    assert {:error, :forbidden} = current(manager, owner_pay)
    assert {:error, :forbidden} = Compensation.list_rate_history(manager, owner_pay)
    assert {:error, :forbidden} = Compensation.set_rate(credential, owner_pay, @attrs, now: @now)
    misclassified = employment_fixture(%{}, business: c.business, user: c.owner)
    assert {:ok, _} = set(c, misclassified)
    assert {:error, :forbidden} = current(manager, misclassified)

    assert {:error, :forbidden} =
             Authorization.authorize(manager, :compensation_write, misclassified)

    Repo.update!(
      change(c.grant,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = current(manager, misclassified)
  end

  test "Shop Managers read only current assigned Detailer pay, with no grant mixing or history access",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :shop_manager)
    {:ok, _} = Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, first} = set(c, c.employment)
    {:ok, future} = set(c, c.employment, Map.put(@attrs, :effective_from, ~D[2026-11-01]))
    assert {:ok, dto} = current(manager, c.employment)
    assert dto.id == first.id and dto.id != future.id
    assert Enum.sort(Map.keys(dto)) == Enum.sort(@keys)
    assert {:error, :forbidden} = Compensation.list_rate_history(manager, c.employment)
    {:ok, _, credential} = Accounts.create_session(manager)

    assert {:error, :forbidden} =
             Compensation.set_rate(credential, c.employment, @attrs, now: @now)

    shop2 = shop_fixture(%{business_id: c.business.id})
    other = employment_fixture(%{}, business: c.business)
    {:ok, _} = Employment.assign_shop(other, shop2, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = set(c, other)
    grant_fixture(manager, shop2, :employee)
    assert {:error, :forbidden} = current(manager, other)
  end

  test "ended/future assignments, archived shops and revoked shop grants remove current Detailer visibility",
       c do
    manager = active_user_fixture()
    {_, grant} = grant_fixture(manager, c.shop, :shop_manager)
    {:ok, assignment} = Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = set(c, c.employment)
    assert {:ok, _} = current(manager, c.employment)
    {:ok, _} = Employment.end_shop_assignment(assignment, ~D[2026-10-29])
    assert {:error, :forbidden} = current(manager, c.employment)
    {:ok, _} = Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-11-01]})
    assert {:error, :forbidden} = current(manager, c.employment)
    assert {:ok, _} = current(manager, c.employment, @later)
    Repo.update!(change(c.shop, status: :archived))
    assert {:error, :forbidden} = current(manager, c.employment, @later)
    Repo.update!(change(c.shop, status: :active))

    Repo.update!(
      change(grant,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = current(manager, c.employment, @later)
  end

  test "management classification and management/Employee role overlap cannot expose management pay",
       c do
    reader = active_user_fixture()
    grant_fixture(reader, c.shop, :shop_manager)

    for classification <- [:shop_manager, :business_manager, :business_owner] do
      target = active_user_fixture()
      grant_fixture(target, c.shop, :employee)

      employment =
        employment_fixture(%{classification: classification}, business: c.business, user: target)

      {:ok, _} = Employment.assign_shop(employment, c.shop, %{starts_on: ~D[2026-01-01]})
      {:ok, _} = set(c, employment)
      assert {:error, :forbidden} = current(reader, employment)
      assert Repo.reload!(employment).classification == classification
    end

    target = active_user_fixture()
    {_, management} = grant_fixture(target, c.shop, :shop_manager)
    grant_fixture(target, c.shop, :employee)
    misclassified = employment_fixture(%{}, business: c.business, user: target)
    {:ok, _} = Employment.assign_shop(misclassified, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = set(c, misclassified)
    assert {:error, :forbidden} = current(reader, misclassified)

    Repo.update!(
      change(management,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = current(reader, misclassified)
  end

  test "own-pay access requires an eligible linked user and matching shop grant, never an email match",
       c do
    employee = active_user_fixture()
    grant_fixture(employee, c.shop, :employee)

    assert {:error, :forbidden} =
             Compensation.get_own_current_rate(employee, c.business, now: @now)

    own =
      employment_fixture(%{classification: :shop_manager}, business: c.business, user: employee)

    {:ok, rate} = set(c, own)

    assert {:error, :forbidden} =
             Compensation.get_own_current_rate(employee, c.business, now: @now)

    {:ok, assignment} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, dto} = Compensation.get_own_current_rate(employee, c.business, now: @now)
    assert dto.id == rate.id
    assert {:error, :forbidden} = current(employee, c.employment)
    assert {:error, :forbidden} = Compensation.list_rate_history(employee, own)
    {:ok, _} = Employment.end_shop_assignment(assignment, ~D[2026-10-30])

    assert {:error, :forbidden} =
             Compensation.get_own_current_rate(employee, c.business, now: @now)
  end

  test "cross-business grants and spoofed ownership cannot authorize pay; unrelated Owner roles stay business-local",
       c do
    foreign = employment_fixture()
    foreign_business = Repo.get!(Business, foreign.business_id)
    assert {:error, :forbidden} = set(c, %{foreign | business_id: c.business.id})
    assert {:error, :forbidden} = current(c.owner, %{foreign | business_id: c.business.id})
    assert {:error, :forbidden} = Compensation.get_own_current_rate(c.owner, foreign_business)
    # A person may own B and detail for A; no global role blacklist.
    foreign_shop = shop_fixture(%{business_id: foreign.business_id})
    worker = active_user_fixture()
    grant_fixture(worker, foreign_shop, :business_owner)
    grant_fixture(worker, c.shop, :employee)
    own = employment_fixture(%{}, business: c.business, user: worker)
    {:ok, _} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = set(c, own)
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :shop_manager)
    assert {:ok, _} = current(manager, own)
  end

  test "ended employment, assignments, rates and audit history are retained; only HR history remains accessible",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :shop_manager)
    {:ok, assignment} = Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, rate} = set(c, c.employment)
    before = Repo.aggregate(CompensationAuditEvent, :count)
    {:ok, ended} = Employment.end_employment(c.employment, ~D[2026-10-30])
    assert Repo.reload!(assignment).status == :ended
    assert Repo.get!(CompensationRate, rate.id).amount == Decimal.new("25.50")
    assert Repo.aggregate(CompensationAuditEvent, :count) == before
    assert {:ok, [stored]} = Compensation.list_rate_history(c.owner, ended)
    assert stored.id == rate.id
    hr = active_user_fixture()
    grant_fixture(hr, c.shop, :business_manager)
    assert {:ok, [_]} = Compensation.list_rate_history(hr, ended)
    assert {:ok, nil} = current(c.owner, ended)
    assert {:error, :forbidden} = current(manager, ended)
    assert {:error, :employment_ended} = set(c, ended)

    for {table, id} <- [{"employments", ended.id}, {"compensation_rates", rate.id}] do
      reject("DELETE FROM #{table} WHERE id=$1", [id], :restrict_violation)
    end
  end

  test "credential, account, membership and tenant revocations are observed immediately", c do
    {:ok, _} = set(c, c.employment)

    for actor <- [
          c.owner,
          %{id: c.owner.id},
          SessionCredential.generate(),
          SessionCredential.reveal(c.credential),
          nil
        ] do
      assert {:error, :forbidden} = Compensation.set_rate(actor, c.employment, @attrs, now: @now)
    end

    {:ok, _} = Accounts.revoke_session(c.session, :logout)
    assert {:error, :forbidden} = set(c, c.employment)

    {:ok, _, expired} =
      Accounts.create_session(c.owner, now: DateTime.add(DateTime.utc_now(), -9 * 3600))

    # The injected financial clock cannot revive an expired real session.
    assert {:error, :forbidden} = Compensation.set_rate(expired, c.employment, @attrs, now: @now)
    {:ok, _, fresh} = Accounts.create_session(c.owner)
    {:ok, _} = Memberships.revoke(c.membership)
    assert {:error, :forbidden} = Compensation.set_rate(fresh, c.employment, @attrs, now: @now)
    assert {:error, :forbidden} = current(c.owner, c.employment)
    {:ok, _} = Memberships.reactivate(c.membership)
    assert {:error, :forbidden} = Compensation.set_rate(fresh, c.employment, @attrs, now: @now)
  end

  test "pending suspended deactivated unverified and archived actors/scopes fail closed", c do
    for status <- [:pending, :suspended, :deactivated, :unverified] do
      actor = active_user_fixture()
      grant_fixture(actor, c.shop, :business_owner)
      {:ok, _, credential} = Accounts.create_session(actor)

      if status == :unverified,
        do: Repo.update!(change(actor, email_verified: false)),
        else: Accounts.set_user_status(actor, status)

      assert {:error, :forbidden} =
               Compensation.set_rate(credential, c.employment, @attrs, now: @now)

      assert {:error, :forbidden} = current(actor, c.employment)
    end

    {:ok, _} = set(c, c.employment)
    Repo.update!(change(c.business, status: :archived))
    assert {:error, :forbidden} = set(c, c.employment)
    assert {:error, :forbidden} = current(c.owner, c.employment)
  end

  test "database rejects cross-tenant rates, overlap, invalid money/basis/currency, empty periods and identity rewrites",
       c do
    foreign = employment_fixture()

    sql =
      "INSERT INTO compensation_rates(business_id,employment_id,amount,pay_basis,currency,effective_from,effective_until,inserted_at) VALUES($1,$2,$3,$4,$5,$6,$7,timezone('UTC',now()))"

    reject(
      sql,
      [
        foreign.business_id,
        c.employment.id,
        Decimal.new("10"),
        "hourly",
        "USD",
        ~D[2026-10-29],
        nil
      ],
      :foreign_key_violation
    )

    for {amount, basis, currency, until} <- [
          {"0", "hourly", "USD", nil},
          {"NaN", "hourly", "USD", nil},
          {"1.001", "hourly", "USD", nil},
          {"10", "commission", "USD", nil},
          {"10", "hourly", "EUR", nil},
          {"10", "hourly", "USD", ~D[2026-10-29]}
        ] do
      reject(
        sql,
        [
          c.business.id,
          c.employment.id,
          Decimal.new(amount),
          basis,
          currency,
          ~D[2026-10-29],
          until
        ],
        :check_violation
      )
    end

    {:ok, rate} = set(c, c.employment)

    reject(
      sql,
      [c.business.id, c.employment.id, Decimal.new("10"), "hourly", "USD", ~D[2026-11-01], nil],
      :exclusion_violation
    )

    reject(
      "UPDATE compensation_rates SET business_id=$1 WHERE id=$2",
      [foreign.business_id, rate.id],
      :check_violation
    )

    reject(
      "UPDATE compensation_rates SET pay_basis='annual_salary' WHERE id=$1",
      [rate.id],
      :check_violation
    )
  end
end
