defmodule SchedulerApi.MembershipPersistenceTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.AccountsFixtures

  alias SchedulerApi.Organizations.{
    Business,
    Shop,
    BusinessMembership,
    RoleAssignment,
    Memberships
  }

  @now ~U[2026-10-29 12:00:00Z]

  setup do
    user = user_fixture()

    business =
      Repo.insert!(%Business{name: "RBAC", slug: "rbac-#{System.unique_integer([:positive])}"})

    shop =
      Repo.insert!(%Shop{
        business_id: business.id,
        name: "Shop",
        slug: "shop",
        timezone: "America/Denver"
      })

    membership =
      Repo.insert!(%BusinessMembership{
        user_id: user.id,
        business_id: business.id,
        inserted_at: @now,
        updated_at: @now
      })

    %{user: user, business: business, shop: shop, membership: membership}
  end

  defp grant(c, role, shop_id \\ nil) do
    %RoleAssignment{
      membership_id: c.membership.id,
      business_id: c.business.id,
      shop_id: shop_id,
      inserted_at: @now,
      updated_at: @now
    }
    |> RoleAssignment.creation_changeset(%{role: role})
    |> Repo.insert()
  end

  # Raw SQL under a savepoint proves rejection without schema/changeset validation.
  defp reject(sql, params, code) do
    result =
      Repo.transaction(
        fn ->
          case Repo.query(sql, params) do
            {:error, %Postgrex.Error{postgres: %{code: ^code}}} -> Repo.rollback(:rejected)
            other -> flunk("Expected database rejection, got #{inspect(other)}")
          end
        end,
        mode: :savepoint
      )

    assert result == {:error, :rejected}
  end

  defp raw(c, role, shop, status \\ "active") do
    Repo.query(
      "INSERT INTO role_assignments(membership_id,business_id,shop_id,role,status,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$6)",
      [c.membership.id, c.business.id, shop, role, status, DateTime.to_naive(@now)]
    )
  end

  test "fixed roles, multiple independent roles/shops/businesses; no implicit grants", c do
    assert RoleAssignment.roles() == [
             :business_owner,
             :business_manager,
             :shop_manager,
             :employee
           ]

    assert Repo.aggregate(RoleAssignment, :count) == 0
    assert c.user.status == :pending
    assert {:error, :ineligible_account} = SchedulerApi.Accounts.create_session(c.user)
    assert {:ok, _} = grant(c, :business_owner)
    assert {:ok, _} = grant(c, :business_manager)
    assert {:ok, _} = grant(c, :shop_manager, c.shop.id)
    assert {:ok, _} = grant(c, :employee, c.shop.id)

    shop2 =
      Repo.insert!(%Shop{
        business_id: c.business.id,
        name: "Two",
        slug: "two",
        timezone: "America/Denver"
      })

    assert {:ok, _} = grant(c, :employee, shop2.id)
    b = Repo.insert!(%Business{name: "Other", slug: "other"})
    assert Repo.insert!(%BusinessMembership{user_id: c.user.id, business_id: b.id})

    assert {:error, _} =
             %BusinessMembership{user_id: c.user.id, business_id: c.business.id}
             |> BusinessMembership.creation_changeset()
             |> Repo.insert()

    assert {:ok, user} = SchedulerApi.Accounts.sync_verified_identity(verified_identity_fixture())
    refute Repo.exists?(from m in BusinessMembership, where: m.user_id == ^user.id)
  end

  test "DB rejects invalid role names including platform/wildcard and invalid scope", c do
    for {role, shop} <- [
          {"god_mode", nil},
          {"platform_admin", nil},
          {"*", nil},
          {"unknown", nil},
          {"business_owner", c.shop.id},
          {"business_manager", c.shop.id},
          {"shop_manager", nil},
          {"employee", nil}
        ] do
      assert {:error, :rejected} =
               Repo.transaction(
                 fn ->
                   assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                            raw(c, role, shop)

                   Repo.rollback(:rejected)
                 end,
                 mode: :savepoint
               )
    end
  end

  test "NULL business scopes and shop scopes enforce active uniqueness", c do
    for {role, shop} <- [
          {:business_owner, nil},
          {:business_manager, nil},
          {:shop_manager, c.shop.id},
          {:employee, c.shop.id}
        ] do
      assert {:ok, _} = grant(c, role, shop)
      assert {:error, changeset} = grant(c, role, shop)
      assert Keyword.has_key?(changeset.errors, :role)
    end
  end

  test "cross-business combinations rejected even via SQL", c do
    b = Repo.insert!(%Business{name: "Other", slug: "other"})

    s =
      Repo.insert!(%Shop{
        business_id: b.id,
        name: "Other",
        slug: "other",
        timezone: "America/Denver"
      })

    reject(
      "INSERT INTO role_assignments(membership_id,business_id,shop_id,role,inserted_at,updated_at) VALUES($1,$2,$3,'employee',$4,$4)",
      [c.membership.id, c.business.id, s.id, DateTime.to_naive(@now)],
      :foreign_key_violation
    )

    assert {:error, :rejected} =
             Repo.transaction(
               fn ->
                 assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                          raw(%{c | business: b}, "business_owner", nil)

                 Repo.rollback(:rejected)
               end,
               mode: :savepoint
             )
  end

  test "revocation is atomic, idempotent and reactivation cannot resurrect old roles", c do
    {:ok, g} = grant(c, :business_owner)
    {:ok, h} = grant(c, :employee, c.shop.id)

    assert {:ok, revoked} =
             Memberships.revoke(c.membership, now: DateTime.add(@now, 1), actor_id: c.user.id)

    for id <- [g.id, h.id] do
      stored = Repo.get!(RoleAssignment, id)
      assert stored.status == :revoked and stored.revocation_reason == :membership_revoked
      assert stored.revoked_by_user_id == c.user.id
    end

    assert {:ok, ^revoked} = Memberships.revoke(c.membership, now: DateTime.add(@now, 2))
    assert {:error, _} = grant(c, :business_manager)
    assert {:ok, _} = Memberships.reactivate(revoked, now: DateTime.add(@now, 3))
    assert Repo.get!(RoleAssignment, g.id).status == :revoked
    assert {:ok, fresh} = grant(c, :business_owner)
    assert fresh.id != g.id

    reject(
      "UPDATE role_assignments SET status='active', revoked_at=NULL, revoked_by_user_id=NULL, revocation_reason=NULL WHERE id=$1",
      [g.id],
      :check_violation
    )
  end

  test "direct SQL membership revocation also revokes grants; invalid lifecycle rejected", c do
    {:ok, g} = grant(c, :employee, c.shop.id)

    reject(
      "UPDATE business_memberships SET status='revoked' WHERE id=$1",
      [c.membership.id],
      :check_violation
    )

    reject(
      "UPDATE business_memberships SET status='unknown' WHERE id=$1",
      [c.membership.id],
      :check_violation
    )

    reject("UPDATE role_assignments SET status='unknown' WHERE id=$1", [g.id], :check_violation)

    Repo.query!(
      "UPDATE business_memberships SET status='revoked',revoked_at=$2,revocation_reason='manual' WHERE id=$1",
      [c.membership.id, DateTime.to_naive(@now)]
    )

    assert Repo.get!(RoleAssignment, g.id).status == :revoked
  end

  test "membership and grant ownership cannot be reassigned", c do
    other = user_fixture()

    reject(
      "UPDATE business_memberships SET user_id=$1 WHERE id=$2",
      [other.id, c.membership.id],
      :check_violation
    )

    {:ok, g} = grant(c, :employee, c.shop.id)

    reject(
      "UPDATE role_assignments SET role='shop_manager' WHERE id=$1",
      [g.id],
      :check_violation
    )
  end

  test "composite membership FK rejects cross-business historical grants", c do
    b = Repo.insert!(%Business{name: "Foreign", slug: "foreign"})

    reject(
      "INSERT INTO role_assignments(membership_id,business_id,role,status,revoked_at,revocation_reason,inserted_at,updated_at) VALUES($1,$2,'business_owner','revoked',$3,'manual',$3,$3)",
      [c.membership.id, b.id, DateTime.to_naive(@now)],
      :foreign_key_violation
    )
  end

  test "restrictive FKs retain membership and grant history", c do
    {:ok, _} = grant(c, :employee, c.shop.id)

    for {table, id} <- [
          {"business_memberships", c.membership.id},
          {"users", c.user.id},
          {"shops", c.shop.id},
          {"businesses", c.business.id}
        ] do
      reject("DELETE FROM #{table} WHERE id=$1", [id], :restrict_violation)
    end
  end
end
