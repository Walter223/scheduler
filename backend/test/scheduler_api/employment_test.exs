defmodule SchedulerApi.EmploymentTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Authorization, Employment}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}

  setup do
    record = employment_fixture()
    business = Repo.get!(Business, record.business_id)
    shop = shop_fixture(%{business_id: business.id})
    %{record: record, business: business, shop: shop}
  end

  defp attrs do
    %{
      first_name: " Alex ",
      last_name: " Driver ",
      classification: :detailer,
      starts_on: ~D[2026-01-01]
    }
  end

  defp member(user, business) do
    Repo.insert!(%BusinessMembership{user_id: user.id, business_id: business.id})
  end

  defp reject(sql, params, code) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Repo.query(sql, params, mode: :savepoint)
  end

  test "nullable identities and explicit fixed classifications create no access", c do
    for classification <- EmploymentRecord.classifications() do
      assert {:ok, e} =
               Employment.create_employment(
                 c.business,
                 Map.put(attrs(), :classification, classification)
               )

      assert e.user_id == nil
      assert e.status == :active
      assert {e.first_name, e.last_name} == {"Alex", "Driver"}
    end

    assert Repo.aggregate(BusinessMembership, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 0

    assert {:error, cs} =
             Employment.create_employment(
               c.business,
               Map.put(attrs(), :classification, :employee)
             )

    assert errors_on(cs).classification

    for field <- [:first_name, :last_name], value <- [nil, "  ", String.duplicate("x", 101)] do
      assert {:error, invalid} =
               Employment.create_employment(c.business, Map.put(attrs(), field, value))

      assert Map.has_key?(errors_on(invalid), field)
    end
  end

  test "login and existing roles do not create employment or change management classification",
       c do
    user = active_user_fixture()
    m = member(user, c.business)

    Repo.insert!(%RoleAssignment{
      membership_id: m.id,
      business_id: c.business.id,
      shop_id: c.shop.id,
      role: :employee
    })

    before = Repo.aggregate(EmploymentRecord, :count)
    assert {:ok, _} = Accounts.sync_verified_identity(verified_identity_fixture())
    assert Repo.aggregate(EmploymentRecord, :count) == before

    assert {:ok, e} =
             Employment.create_employment(
               c.business,
               Map.put(attrs(), :classification, :shop_manager),
               user: user
             )

    assert e.classification == :shop_manager

    assert {:error, :forbidden} =
             Authorization.authorize(user, :assigned_employee_compensation_read, e)

    assert Repo.aggregate(RoleAssignment, :count) == 1
  end

  test "user links require persisted active verified identity and same-business membership", c do
    user = active_user_fixture()
    assert {:error, cs} = Employment.create_employment(c.business, attrs(), user: user)
    assert errors_on(cs).user_id
    member(user, c.business)
    assert {:ok, e} = Employment.create_employment(c.business, attrs(), user: user)
    assert e.user_id == user.id
    assert {:error, duplicate} = Employment.create_employment(c.business, attrs(), user: user)
    assert errors_on(duplicate).user_id
    assert {:ok, ended} = Employment.end_employment(e, ~D[2026-02-01])
    assert ended.user_id == user.id
    assert {:error, _} = Employment.create_employment(c.business, attrs(), user: user)
    other = Repo.insert!(%Business{name: "Other", slug: "other"})
    assert {:error, _} = Employment.create_employment(other, attrs(), user: user)
    member(user, other)
    assert {:ok, different} = Employment.create_employment(other, attrs(), user: user)
    assert different.user_id == user.id
    refute different.business_id == e.business_id
  end

  test "stale eligible user structs cannot bypass current account or membership lifecycle", c do
    for status <- [:pending, :suspended, :deactivated, :unverified, :revoked] do
      user = active_user_fixture()
      m = member(user, c.business)

      case status do
        :unverified -> Repo.update!(change(user, email_verified: false))
        :revoked -> SchedulerApi.Organizations.Memberships.revoke(m)
        status -> Accounts.set_user_status(user, status)
      end

      assert {:error, cs} = Employment.create_employment(c.business, attrs(), user: user)
      assert errors_on(cs).user_id
    end

    assert {:error, _} =
             Employment.create_employment(c.business, attrs(),
               user: %SchedulerApi.Accounts.User{id: -1}
             )
  end

  test "ownership and user links are not mass assignable; retrieval is business scoped", c do
    foreign = employment_fixture()
    other_business = Repo.get!(Business, foreign.business_id)

    spoofed =
      Map.merge(attrs(), %{
        business_id: foreign.business_id,
        user_id: -1,
        status: :ended,
        ends_on: ~D[2026-01-02]
      })

    assert {:ok, e} = Employment.create_employment(c.business, spoofed)
    assert e.business_id == c.business.id and is_nil(e.user_id) and e.status == :active
    assert Employment.get_employment(other_business, e.id) == nil
    assert Enum.all?(Employment.list_employments(c.business), &(&1.business_id == c.business.id))

    assert {:ok, assignment} =
             Employment.assign_shop(c.record, c.shop, %{
               starts_on: ~D[2026-01-01],
               business_id: foreign.business_id,
               employment_id: foreign.id,
               shop_id: -1
             })

    assert assignment.business_id == c.business.id and assignment.employment_id == c.record.id
    assert Employment.list_shop_assignments(other_business, c.record) == []
    foreign_shop = shop_fixture(%{business_id: foreign.business_id})

    assert {:error, :wrong_business} =
             Employment.assign_shop(c.record, %{foreign_shop | business_id: c.business.id}, %{
               starts_on: ~D[2026-01-01]
             })
  end

  test "multiple shops, duplicate active assignments and ended assignment history", c do
    second = shop_fixture(%{business_id: c.business.id})
    assert {:ok, a} = Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]})
    assert {:ok, _} = Employment.assign_shop(c.record, second, %{starts_on: ~D[2026-01-01]})
    assert {:error, cs} = Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]})
    assert errors_on(cs).shop_id
    assert {:error, :invalid_end_date} = Employment.end_shop_assignment(a, ~D[2025-12-31])
    assert {:ok, ended} = Employment.end_shop_assignment(a, ~D[2026-01-02])
    assert {:ok, ^ended} = Employment.end_shop_assignment(a, ~D[2026-01-02])
    assert {:error, :already_ended} = Employment.end_shop_assignment(a, ~D[2026-01-03])
    assert {:ok, fresh} = Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-03]})
    refute fresh.id == a.id
    assert Repo.get!(ShopAssignment, a.id).status == :ended
    assert length(Employment.list_shop_assignments(c.business, c.record)) == 3
  end

  test "employment ending is atomic, terminal, idempotent and closes every active assignment",
       c do
    assert {:ok, a} = Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-02-01]})
    assert {:error, :invalid_end_date} = Employment.end_employment(c.record, ~D[2026-01-31])
    assert Repo.reload!(a).status == :active
    assert Repo.reload!(c.record).status == :active
    assert {:ok, ended} = Employment.end_employment(c.record, ~D[2026-02-02])
    assert Repo.reload!(a).ends_on == ended.ends_on
    assert {:ok, ^ended} = Employment.end_employment(c.record, ~D[2026-02-02])
    assert {:error, :already_ended} = Employment.end_employment(c.record, ~D[2026-03-01])

    assert {:error, :employment_ended} =
             Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-03-01]})

    reject(
      "UPDATE employments SET status='active', ends_on=NULL WHERE id=$1",
      [ended.id],
      :check_violation
    )

    reject(
      "UPDATE employment_shop_assignments SET status='active', ends_on=NULL WHERE id=$1",
      [a.id],
      :check_violation
    )
  end

  test "linked employment survives account/membership changes without restoring grants", c do
    user = active_user_fixture()
    membership = member(user, c.business)
    assert {:ok, e} = Employment.create_employment(c.business, attrs(), user: user)
    assert {:ok, _} = Accounts.set_user_status(user, :suspended)
    assert {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(membership)
    assert Repo.reload!(e) == e
    assert Repo.aggregate(RoleAssignment, :count) == 0
    reject("DELETE FROM users WHERE id=$1", [user.id], :restrict_violation)
    reject("UPDATE employments SET user_id=NULL WHERE id=$1", [e.id], :check_violation)
    assert {:ok, _} = Employment.end_employment(e, ~D[2026-02-01])
  end

  test "raw insertion validates primary classification, independently of immutable-update guards",
       c do
    for classification <- ["employee", "god_mode", "invalid"] do
      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :check_violation,
                  constraint: "employments_classification_valid"
                }
              }} =
               Repo.query(
                 "INSERT INTO employments(business_id,first_name,last_name,classification,starts_on,inserted_at,updated_at) VALUES($1,'A','B',$2,'2026-01-01',timezone('UTC',now()),timezone('UTC',now()))",
                 [c.business.id, classification],
                 mode: :savepoint
               )
    end

    management = employment_fixture(%{classification: :business_owner}, business: c.business)

    reject(
      "UPDATE employments SET classification='detailer' WHERE id=$1",
      [management.id],
      :check_violation
    )

    assert Repo.reload!(management).classification == :business_owner
  end

  test "archived shops/businesses and missing references are rejected", c do
    Repo.update!(change(c.shop, status: :archived))

    assert {:error, :inactive_shop} =
             Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]})

    Repo.update!(change(c.business, status: :archived))
    assert {:error, :inactive_business} = Employment.create_employment(c.business, attrs())

    assert {:error, :inactive_business} =
             Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]})

    assert {:error, :business_not_found} =
             Employment.create_employment(%Business{id: -1}, attrs())
  end

  test "database rejects invalid classifications, lifecycle, nulls and blank names", c do
    for {field, value, code} <- [
          {"classification", "employee", :check_violation},
          {"classification", "god_mode", :check_violation},
          {"status", "unknown", :check_violation},
          {"first_name", " ", :check_violation},
          {"first_name", nil, :not_null_violation},
          {"classification", nil, :check_violation}
        ] do
      reject("UPDATE employments SET #{field}=$1 WHERE id=$2", [value, c.record.id], code)
    end

    reject(
      "INSERT INTO employments(business_id,first_name,last_name,classification,starts_on,inserted_at,updated_at) VALUES($1,'A','B',NULL,'2026-01-01',timezone('UTC',now()),timezone('UTC',now()))",
      [c.business.id],
      :not_null_violation
    )

    reject(
      "UPDATE employments SET status='ended', ends_on='2025-12-31' WHERE id=$1",
      [c.record.id],
      :check_violation
    )

    reject("UPDATE employments SET user_id=-1 WHERE id=$1", [c.record.id], :check_violation)

    assert {:error, cs} =
             Employment.create_employment(c.business, Map.put(attrs(), :starts_on, "bad"))

    assert errors_on(cs).starts_on

    reject(
      "UPDATE employments SET first_name=repeat('x',101) WHERE id=$1",
      [c.record.id],
      :string_data_right_truncation
    )
  end

  test "raw SQL enforces composite ownership, dates, uniqueness and restrictive deletion", c do
    foreign = employment_fixture()
    foreign_shop = shop_fixture(%{business_id: foreign.business_id})
    assert {:ok, a} = Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]})

    sql =
      "INSERT INTO employment_shop_assignments(employment_id,business_id,shop_id,starts_on,inserted_at,updated_at) VALUES($1,$2,$3,$4,timezone('UTC',now()),timezone('UTC',now()))"

    reject(
      sql,
      [c.record.id, foreign.business_id, foreign_shop.id, ~D[2026-01-01]],
      :foreign_key_violation
    )

    reject(
      sql,
      [c.record.id, c.business.id, foreign_shop.id, ~D[2026-01-01]],
      :foreign_key_violation
    )

    reject(sql, [c.record.id, c.business.id, c.shop.id, ~D[2026-01-01]], :unique_violation)
    reject(sql, [c.record.id, c.business.id, c.shop.id, ~D[2025-12-31]], :check_violation)

    reject(
      "UPDATE employment_shop_assignments SET status='ended', ends_on='2025-12-31' WHERE id=$1",
      [a.id],
      :check_violation
    )

    reject(
      "UPDATE employment_shop_assignments SET status='invalid' WHERE id=$1",
      [a.id],
      :check_violation
    )

    reject(
      "UPDATE employments SET status='ended', ends_on='2026-02-01' WHERE id=$1",
      [c.record.id],
      :check_violation
    )

    reject(
      "UPDATE employments SET business_id=$1 WHERE id=$2",
      [foreign.business_id, c.record.id],
      :check_violation
    )

    reject(
      "UPDATE employment_shop_assignments SET shop_id=$1 WHERE id=$2",
      [foreign_shop.id, a.id],
      :check_violation
    )

    for {table, id} <- [
          {"employments", c.record.id},
          {"shops", c.shop.id},
          {"businesses", c.business.id}
        ] do
      reject("DELETE FROM #{table} WHERE id=$1", [id], :restrict_violation)
    end
  end
end
