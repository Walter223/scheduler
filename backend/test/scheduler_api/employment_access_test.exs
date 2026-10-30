defmodule SchedulerApi.EmploymentAccessTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Authorization, Employment}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, Memberships}

  @now ~U[2026-10-29 18:00:00Z]
  @keys [
    :id,
    :business_id,
    :first_name,
    :last_name,
    :classification,
    :starts_on,
    :phone,
    :email,
    :home_address
  ]

  setup do
    record = employment_fixture()
    business = Repo.get!(Business, record.business_id)
    shop = shop_fixture(%{business_id: business.id})
    second_shop = shop_fixture(%{business_id: business.id})

    record =
      Repo.update!(
        change(record,
          phone: "3035550100",
          email: "employment@example.invalid",
          home_address: "123 Test Street"
        )
      )

    {:ok, assignment} = Employment.assign_shop(record, shop, %{starts_on: ~D[2026-01-01]})
    foreign = employment_fixture()
    foreign_business = Repo.get!(Business, foreign.business_id)
    foreign_shop = shop_fixture(%{business_id: foreign.business_id})
    {:ok, _} = Employment.assign_shop(foreign, foreign_shop, %{starts_on: ~D[2026-01-01]})

    %{
      user: active_user_fixture(),
      record: record,
      business: business,
      shop: shop,
      second_shop: second_shop,
      assignment: assignment,
      foreign: foreign,
      foreign_business: foreign_business,
      foreign_shop: foreign_shop
    }
  end

  defp business_roster(c, opts \\ []),
    do: Employment.list_business_roster(c.user, c.business, Keyword.merge([now: @now], opts))

  defp shop_roster(c, opts \\ []),
    do: Employment.list_shop_roster(c.user, c.shop, Keyword.merge([now: @now], opts))

  defp ids(page), do: Enum.map(page.employments, & &1.id)

  test "Owner and Business Manager HR rosters include only own-business active records and exact contact fields",
       c do
    unassigned = employment_fixture(%{classification: :business_manager}, business: c.business)

    for role <- [:business_owner, :business_manager] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      assert {:ok, page} = business_roster(%{c | user: user})
      assert ids(page) == [c.record.id, unassigned.id]
      assert Enum.all?(page.employments, &(Enum.sort(Map.keys(&1)) == Enum.sort(@keys)))

      assert hd(page.employments) == %{
               id: c.record.id,
               business_id: c.business.id,
               first_name: "Taylor",
               last_name: "Worker",
               classification: :detailer,
               starts_on: ~D[2026-01-01],
               phone: "3035550100",
               email: "employment@example.invalid",
               home_address: "123 Test Street"
             }

      assert {:error, :forbidden} = Employment.list_business_roster(user, c.foreign_business)
      assert :ok = Authorization.authorize(user, :employment_private_read, c.record)

      assert {:error, :forbidden} =
               Authorization.authorize(user, :employment_private_read, c.foreign)
    end
  end

  test "Shop Manager sees unlinked and management staff contacts only at assigned shops", c do
    grant_fixture(c.user, c.shop, :shop_manager)
    management = employment_fixture(%{classification: :shop_manager}, business: c.business)
    {:ok, _} = Employment.assign_shop(management, c.shop, %{starts_on: ~D[2026-01-01]})
    elsewhere = employment_fixture(%{}, business: c.business)
    {:ok, _} = Employment.assign_shop(elsewhere, c.second_shop, %{starts_on: ~D[2026-01-01]})
    assert c.record.user_id == nil
    assert {:ok, page} = shop_roster(c)
    assert ids(page) == [c.record.id, management.id]
    assert Enum.all?(page.employments, &(Enum.sort(Map.keys(&1)) == Enum.sort(@keys)))
    assert {:error, :forbidden} = business_roster(c)
    assert {:error, :forbidden} = Employment.list_shop_roster(c.user, c.second_shop)
    assert {:error, :forbidden} = Employment.list_shop_roster(c.user, c.foreign_shop)
    assert :ok = Authorization.authorize(c.user, :assigned_employee_contact_read, c.record)

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :assigned_employee_contact_read, elsewhere)

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :assigned_employee_compensation_read, management)
  end

  test "business HR grants do not create shop operational permissions", c do
    grant_fixture(c.user, c.shop, :business_manager)
    assert {:ok, _} = business_roster(c)
    assert {:error, :forbidden} = shop_roster(c)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.shop)
  end

  test "multiple independent shop grants work without combining unrelated permissions/scopes",
       c do
    grant_fixture(c.user, c.shop, :shop_manager)
    grant_fixture(c.user, c.second_shop, :employee)
    grant_fixture(c.user, c.foreign_shop, :business_manager)
    assert {:ok, _} = shop_roster(c)
    assert {:error, :forbidden} = Employment.list_shop_roster(c.user, c.second_shop)
    assert {:error, :forbidden} = Employment.list_shop_roster(c.user, c.foreign_shop)

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :assigned_employee_contact_read, c.foreign)

    assert {:error, :forbidden} = business_roster(c)
    assert {:ok, page} = Employment.list_business_roster(c.user, c.foreign_business, now: @now)
    assert ids(page) == [c.foreign.id]
    grant_fixture(c.user, c.second_shop, :shop_manager)

    assert {:ok, %{employments: []}} =
             Employment.list_shop_roster(c.user, c.second_shop, now: @now)
  end

  test "overlapping grants and multi-shop staff do not duplicate records or leak into cursors",
       c do
    grant_fixture(c.user, c.shop, :business_owner)
    grant_fixture(c.user, c.shop, :shop_manager)
    {:ok, _} = Employment.assign_shop(c.record, c.second_shop, %{starts_on: ~D[2026-01-01]})
    second = employment_fixture(%{}, business: c.business)
    {:ok, _} = Employment.assign_shop(second, c.shop, %{starts_on: ~D[2026-01-01]})
    # Foreign fixture's ID falls between the two visible records.
    assert c.record.id < c.foreign.id and c.foreign.id < second.id
    assert {:ok, first} = shop_roster(c, limit: 1)
    assert ids(first) == [c.record.id] and first.has_more

    assert Jason.decode!(Base.url_decode64!(first.next_cursor, padding: false)) == [
             1,
             c.record.id
           ]

    assert {:ok, last} = shop_roster(c, limit: 1, cursor: first.next_cursor)
    assert ids(last) == [second.id] and not last.has_more and is_nil(last.next_cursor)
    forged = Jason.encode!([1, c.foreign.id]) |> Base.url_encode64(padding: false)
    assert {:ok, after_foreign} = shop_roster(c, cursor: forged)
    assert ids(after_foreign) == [second.id]
    assert {:ok, hr} = business_roster(c, limit: 1)
    assert ids(hr) == [c.record.id] and hr.has_more
  end

  test "self-service requires the caller's linked identity, complete grant and matching active shop assignment",
       c do
    grant_fixture(c.user, c.shop, :employee)
    Repo.update!(change(c.record, email: c.user.email))
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
    own = employment_fixture(%{classification: :shop_manager}, business: c.business, user: c.user)
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
    {:ok, wrong} = Employment.assign_shop(own, c.second_shop, %{starts_on: ~D[2026-01-01]})
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
    {:ok, assigned} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, dto} = Employment.get_own_employment(c.user, c.business, now: @now)
    assert dto.id == own.id and dto.classification == :shop_manager
    assert Enum.sort(Map.keys(dto)) == Enum.sort(@keys)
    assert dto.email == nil and dto.phone == nil and dto.home_address == nil
    refute c.user.email == nil
    assert :ok = Authorization.authorize(c.user, :employment_own_read, own)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :employment_own_read, c.record)
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.foreign_business)
    assert {:error, :forbidden} = shop_roster(c)
    assert {:error, :forbidden} = business_roster(c)
    assert {:ok, _} = Employment.end_shop_assignment(assigned, ~D[2026-02-01])
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
    assert Repo.reload!(wrong).status == :active
    assert Repo.reload!(own).classification == :shop_manager
  end

  test "same person can self-serve distinct businesses only through each matching assignment",
       c do
    grant_fixture(c.user, c.shop, :employee)
    grant_fixture(c.user, c.foreign_shop, :employee)
    own = employment_fixture(%{}, business: c.business, user: c.user)
    other = employment_fixture(%{}, business: c.foreign_business, user: c.user)
    {:ok, _} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, dto} = Employment.get_own_employment(c.user, c.business, now: @now)
    assert dto.id == own.id

    assert {:error, :forbidden} =
             Employment.get_own_employment(c.user, c.foreign_business, now: @now)

    {:ok, _} = Employment.assign_shop(other, c.foreign_shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, dto} = Employment.get_own_employment(c.user, c.foreign_business, now: @now)
    assert dto.id == other.id
  end

  test "classification and a linked identity alone grant no self-service or HR access", c do
    Repo.insert!(%BusinessMembership{business_id: c.business.id, user_id: c.user.id})

    own =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: c.user)

    {:ok, _} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:error, :forbidden} = business_roster(c)
    assert {:error, :forbidden} = shop_roster(c)
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :employment_private_read, own)
  end

  test "revoked memberships/grants affect subsequent SQL and reactivation restores no grant", c do
    {membership, _} = grant_fixture(c.user, c.shop, :business_owner)
    query = Authorization.authorized_employment_ids_query(c.user, :employment_private_read, @now)
    assert Repo.all(query) != []
    assert {:ok, _} = Memberships.revoke(membership)
    assert Repo.all(query) == []
    assert {:error, :forbidden} = business_roster(c)
    assert {:error, :forbidden} = shop_roster(c)
    assert {:ok, _} = Memberships.reactivate(membership)
    assert {:error, :forbidden} = business_roster(c)
    {_, grant} = grant_fixture(c.user, c.shop, :shop_manager)
    assert {:ok, _} = shop_roster(c)

    Repo.update!(
      change(grant,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = shop_roster(c)
  end

  test "pending suspended deactivated and unverified actors fail despite stale eligible structs",
       c do
    for status <- [:pending, :suspended, :deactivated, :unverified] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, :business_owner)
      own = employment_fixture(%{}, business: c.business, user: user)

      if status == :unverified,
        do: Repo.update!(change(user, email_verified: false)),
        else: Accounts.set_user_status(user, status)

      assert {:error, :forbidden} = business_roster(%{c | user: user})
      assert {:error, :forbidden} = shop_roster(%{c | user: user})
      assert {:error, :forbidden} = Employment.get_own_employment(user, c.business)
      assert {:error, :forbidden} = Authorization.authorize(user, :employment_own_read, own)
    end
  end

  test "ended assignments/employment disappear; archived scopes cannot authorize", c do
    grant_fixture(c.user, c.shop, :business_owner)
    assert {:ok, _} = Employment.end_shop_assignment(c.assignment, ~D[2026-02-01])
    assert {:ok, %{employments: []}} = shop_roster(c)
    assert {:ok, hr} = business_roster(c)
    assert ids(hr) == [c.record.id]
    assert {:ok, _} = Employment.end_employment(c.record, ~D[2026-03-01])
    assert {:ok, %{employments: []}} = business_roster(c)

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :employment_private_read, c.record)

    Repo.update!(change(c.shop, status: :archived))
    assert {:error, :forbidden} = shop_roster(c)
    Repo.update!(change(c.business, status: :archived))
    assert {:error, :forbidden} = business_roster(c)
  end

  test "archived shops deny employee self-service even if another ungranted assignment remains",
       c do
    grant_fixture(c.user, c.shop, :employee)
    own = employment_fixture(%{}, business: c.business, user: c.user)

    for shop <- [c.shop, c.second_shop] do
      {:ok, _} = Employment.assign_shop(own, shop, %{starts_on: ~D[2026-01-01]})
    end

    assert {:ok, _} = Employment.get_own_employment(c.user, c.business, now: @now)
    Repo.update!(change(c.shop, status: :archived))
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
    owner = active_user_fixture()
    grant_fixture(owner, c.shop, :business_owner)
    assert {:error, :forbidden} = Employment.list_shop_roster(owner, c.shop, now: @now)
    # HR scope is the active business, not the archived shop: employment still exists.
    assert {:ok, page} = Employment.list_business_roster(owner, c.business, now: @now)
    assert own.id in ids(page)
  end

  test "disabling the target account does not erase active staff from authorized HR/contact rosters",
       c do
    grant_fixture(c.user, c.shop, :business_owner)
    target = active_user_fixture()
    grant_fixture(target, c.shop, :employee)
    staff = employment_fixture(%{}, business: c.business, user: target)
    {:ok, _} = Employment.assign_shop(staff, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, _} = Accounts.set_user_status(target, :suspended)
    assert {:ok, hr} = business_roster(c)
    assert staff.id in ids(hr)
    assert {:ok, contacts} = shop_roster(c)
    assert staff.id in ids(contacts)
    assert {:error, :forbidden} = Employment.get_own_employment(target, c.business, now: @now)
  end

  test "Owner self-service uses a business-wide own-read grant without an artificial shop assignment",
       c do
    grant_fixture(c.user, c.shop, :business_owner)

    own =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: c.user)

    assert {:ok, dto} = Employment.get_own_employment(c.user, c.business, now: @now)
    assert dto.id == own.id
    assert Enum.sort(Map.keys(dto)) == Enum.sort(@keys)
    assert {:ok, _} = Employment.end_employment(own, ~D[2026-02-01])
    assert {:error, :forbidden} = Employment.get_own_employment(c.user, c.business, now: @now)
  end

  test "future employment and assignment starts use the Denver date boundary", c do
    grant_fixture(c.user, c.shop, :shop_manager)
    future = employment_fixture(%{starts_on: ~D[2026-10-30]}, business: c.business)
    {:ok, _} = Employment.assign_shop(future, c.shop, %{starts_on: ~D[2026-10-30]})
    early = ~U[2026-10-30 05:59:59Z]
    later = ~U[2026-10-30 06:00:00Z]
    assert {:ok, before} = shop_roster(c, now: early)
    assert ids(before) == [c.record.id]
    assert {:ok, after_midnight} = shop_roster(c, now: later)
    assert ids(after_midnight) == [c.record.id, future.id]
    employee = active_user_fixture()
    grant_fixture(employee, c.shop, :employee)
    own = employment_fixture(%{}, business: c.business, user: employee)
    {:ok, _} = Employment.assign_shop(own, c.shop, %{starts_on: ~D[2026-10-30]})
    assert {:error, :forbidden} = Employment.get_own_employment(employee, c.business, now: early)
    assert {:ok, _} = Employment.get_own_employment(employee, c.business, now: later)
  end

  test "resource structs cannot spoof persisted business shop or linked-user ownership", c do
    grant_fixture(c.user, c.shop, :shop_manager)

    assert {:error, :forbidden} =
             Employment.list_shop_roster(c.user, %{c.foreign_shop | business_id: c.business.id})

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :assigned_employee_contact_read, %{
               c.foreign
               | business_id: c.business.id,
                 user_id: c.user.id
             })

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :employment_own_read, %{
               c.foreign
               | user_id: c.user.id
             })

    assert {:error, :forbidden} = Employment.list_business_roster(c.user, %Business{id: -1})
    assert {:error, :forbidden} = Employment.list_shop_roster(nil, c.shop)

    assert Repo.all(
             Authorization.authorized_employment_ids_query(
               c.user,
               :assigned_employee_compensation_read
             )
           ) == []
  end

  test "contact columns stay nullable and are never accepted by existing creation writes", c do
    e =
      employment_fixture(%{phone: "ignored", email: "ignored", home_address: "ignored"},
        business: c.business
      )

    assert e.phone == nil and e.email == nil and e.home_address == nil

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE employments SET phone=' ' WHERE id=$1", [e.id], mode: :savepoint)

    assert {:error, %Postgrex.Error{postgres: %{code: :string_data_right_truncation}}} =
             Repo.query(
               "UPDATE employments SET home_address=repeat('x',1001) WHERE id=$1",
               [e.id],
               mode: :savepoint
             )
  end

  test "pagination options are bounded and malformed cursors never become authority", c do
    grant_fixture(c.user, c.shop, :business_owner)
    assert {:ok, _} = business_roster(c, limit: 100)

    for value <- [0, -1, 101, "1", nil] do
      assert {:error, :invalid_limit} = business_roster(c, limit: value)
    end

    for value <- [
          "invalid",
          12,
          String.duplicate("x", 129),
          Base.url_encode64("[1,0]", padding: false)
        ] do
      assert {:error, :invalid_cursor} = business_roster(c, cursor: value)
    end

    assert {:error, :invalid_clock} = business_roster(c, now: "bad")
    assert {:error, :invalid_options} = business_roster(c, shop_id: c.foreign_shop.id)
    assert {:error, :invalid_options} = Employment.list_business_roster(c.user, c.business, %{})
  end
end
