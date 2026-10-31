defmodule SchedulerApi.RoleManagementTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  alias SchedulerApi.{Accounts, Authorization}
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.Authorization.{RoleManagement, AuditEvent}
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}

  setup do
    business =
      Repo.insert!(%Business{name: "Audit", slug: "audit-#{System.unique_integer([:positive])}"})

    owner = active_user_fixture()
    membership = member(owner, business)

    role =
      Repo.insert!(%RoleAssignment{
        membership_id: membership.id,
        business_id: business.id,
        role: :business_owner
      })

    {:ok, session, credential} = Accounts.create_session(owner)
    target = active_user_fixture()

    %{
      business: business,
      owner: owner,
      owner_membership: membership,
      owner_role: role,
      credential: credential,
      session: session,
      target: target,
      membership: member(target, business)
    }
  end

  defp shop(b),
    do:
      Repo.insert!(%Shop{
        business_id: b.id,
        name: "Delegation",
        slug: "delegation",
        timezone: "America/Denver"
      })

  defp manager(c) do
    {:ok, _} =
      RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    {:ok, _, credential} = Accounts.create_session(c.target)
    credential
  end

  test "Owner inheritance is explicit and independently scoped across grants and tenants", c do
    assert Authorization.permissions(:business_manager) --
             Authorization.permissions(:business_owner) == []

    assert {:ok, r} =
             RoleManagement.grant_role(
               c.credential,
               c.business,
               c.owner_membership,
               :business_manager
             )

    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, r)

    for action <-
          Authorization.permissions(:business_manager) --
            [:employment_terminate, :employment_rehire] do
      assert :ok = Authorization.authorize(c.owner, action, c.business)
    end

    assert Repo.aggregate(from(r in RoleAssignment, where: r.status == :active), :count) == 1
    other = Repo.insert!(%Business{name: "Other", slug: "other"})
    m = member(c.owner, other)

    Repo.insert!(%RoleAssignment{
      membership_id: m.id,
      business_id: other.id,
      role: :business_manager
    })

    assert :ok = Authorization.authorize(c.owner, :staff_access_manage, other)
    assert {:error, :forbidden} = Authorization.authorize(c.owner, :access_manage, other)
    {:ok, _} = RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner)
    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, c.owner_role)
    assert {:error, :forbidden} = Authorization.authorize(c.owner, :access_manage, c.business)
    # Removing Owner never manufactures authority from a revoked Manager grant.
    assert {:error, :forbidden} = Authorization.authorize(c.owner, :finance_manage, c.business)
  end

  test "Manager delegates lower roles, never self higher roles or membership lifecycle", c do
    credential = manager(c)
    target = member(active_user_fixture(), c.business)
    shop = shop(c.business)

    for role <- [:employee, :shop_manager] do
      assert {:ok, r} = RoleManagement.grant_role(credential, c.business, target, role, shop)
      assert {:ok, _} = RoleManagement.revoke_role(credential, c.business, r)

      assert {:error, :forbidden} =
               RoleManagement.grant_role(credential, c.business, c.membership, role, shop)
    end

    for role <- [:business_manager, :business_owner] do
      assert {:error, :forbidden} =
               RoleManagement.grant_role(credential, c.business, target, role)

      {:ok, r} = RoleManagement.grant_role(c.credential, c.business, target, role)
      assert {:error, :forbidden} = RoleManagement.revoke_role(credential, c.business, r)
      assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, r)
    end

    assert {:error, :forbidden} = RoleManagement.revoke_membership(credential, c.business, target)
    assert {:ok, _} = RoleManagement.revoke_membership(c.credential, c.business, target)

    assert {:error, :forbidden} =
             RoleManagement.reactivate_membership(credential, c.business, target)
  end

  test "Manager cannot modify current or historical Owner targets even through Employee grants",
       c do
    credential = manager(c)
    shop = shop(c.business)

    for history <- [:classification, :grant] do
      u = active_user_fixture()
      m = member(u, c.business)

      e =
        SchedulerApi.EmploymentFixtures.employment_fixture(
          %{classification: if(history == :classification, do: :business_owner, else: :detailer)},
          business: c.business,
          user: u
        )

      if history == :classification do
        assert {:ok, _} =
                 SchedulerApi.Employment.HR.change_classification(c.credential, e, :detailer)
      else
        {:ok, r} = RoleManagement.grant_role(c.credential, c.business, m, :business_owner)
        assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, r)
      end

      {:ok, lower} = RoleManagement.grant_role(c.credential, c.business, m, :employee, shop)
      assert {:error, :forbidden} = RoleManagement.revoke_role(credential, c.business, lower)

      assert {:error, :forbidden} =
               RoleManagement.grant_role(credential, c.business, m, :shop_manager, shop)
    end
  end

  test "terminated employment cannot gain fresh grants after membership-only reactivation", c do
    credential = manager(c)
    u = active_user_fixture()
    m = member(u, c.business)
    e = SchedulerApi.EmploymentFixtures.employment_fixture(%{}, business: c.business, user: u)
    assert {:ok, _} = SchedulerApi.Employment.HR.terminate_employment(c.credential, e)
    assert {:ok, _} = RoleManagement.reactivate_membership(c.credential, c.business, m)
    shop = shop(c.business)

    for actor <- [credential, c.credential] do
      assert {:error, :ineligible_target} =
               RoleManagement.grant_role(actor, c.business, m, :employee, shop)
    end
  end

  defp member(u, b), do: Repo.insert!(%BusinessMembership{user_id: u.id, business_id: b.id})

  test "authorized scoped grant, duplicate denial, revocation and audit details", c do
    s =
      Repo.insert!(%Shop{
        business_id: c.business.id,
        name: "Shop",
        slug: "shop",
        timezone: "America/Denver"
      })

    assert {:ok, r} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :shop_manager, s)

    e = Repo.one!(AuditEvent)

    assert {e.actor_user_id, e.target_user_id, e.business_id, e.role, e.shop_id, e.outcome} ==
             {c.owner.id, c.target.id, c.business.id, :shop_manager, s.id, :applied}

    assert e.role_assignment_id == r.id and e.occurred_at

    assert {:error, :duplicate_grant} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :shop_manager, s)

    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, r)
    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, r)
    assert Repo.get!(RoleAssignment, r.id).status == :revoked

    assert Enum.map(Repo.all(from e in AuditEvent, order_by: e.id), & &1.outcome) == [
             :applied,
             :denied,
             :applied,
             :noop
           ]

    raw =
      Repo.query!("SELECT json_agg(e)::text FROM authorization_audit_events e").rows
      |> hd()
      |> hd()

    refute raw =~ SessionCredential.reveal(c.credential)
  end

  test "claimed actors, revoked sessions and non-Owners cannot mutate", c do
    for actor <- [c.owner, %{id: c.owner.id}, SessionCredential.generate(), nil] do
      assert {:error, :forbidden} =
               RoleManagement.grant_role(actor, c.business, c.membership, :business_owner)
    end

    {:ok, _, other} = Accounts.create_session(c.target)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(other, c.business, c.membership, :business_owner)

    {:ok, _} = Accounts.revoke_session(c.session, :logout)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner)

    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 6
  end

  test "cross-business target, spoofed membership, invalid scope and roles denied", c do
    foreign = Repo.insert!(%Business{name: "Foreign", slug: "foreign"})
    m = member(c.target, foreign)

    s =
      Repo.insert!(%Shop{
        business_id: foreign.id,
        name: "Other",
        slug: "other",
        timezone: "America/Denver"
      })

    assert {:error, :invalid_target} =
             RoleManagement.grant_role(c.credential, c.business, m, :business_owner)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(c.credential, foreign, m, :business_owner)

    assert {:error, :invalid_target} =
             RoleManagement.grant_role(
               c.credential,
               c.business,
               %{c.membership | user_id: c.owner.id},
               :business_owner
             )

    assert {:error, :invalid_scope} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :employee, s)

    assert {:error, :invalid_scope} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner, s)

    for role <- [:god_mode, :platform_admin, :unknown, "business_owner"] do
      assert {:error, :invalid_role} =
               RoleManagement.grant_role(c.credential, c.business, c.membership, role)
    end

    assert Repo.aggregate(RoleAssignment, :count) == 1
  end

  test "Managers cannot grant Owner roles or bypass scope validation", c do
    assert {:ok, _} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    shop =
      Repo.insert!(%Shop{
        business_id: c.business.id,
        name: "Scope",
        slug: "scope",
        timezone: "America/Denver"
      })

    assert {:ok, _} =
             RoleManagement.grant_role(
               c.credential,
               c.business,
               c.membership,
               :shop_manager,
               shop
             )

    {:ok, _, token} = Accounts.create_session(c.target)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(token, c.business, c.membership, :business_owner)

    Repo.update!(change(shop, status: :archived))

    assert {:error, :invalid_scope} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :employee, shop)

    assert {:error, :invalid_target} =
             RoleManagement.grant_role(
               c.credential,
               c.business,
               %BusinessMembership{},
               :business_owner
             )
  end

  test "last Owner role/membership protected; another eligible Owner permits removal", c do
    assert {:error, :last_owner} =
             RoleManagement.revoke_role(c.credential, c.business, c.owner_role)

    assert {:error, :last_owner} =
             RoleManagement.revoke_membership(c.credential, c.business, c.owner_membership)

    assert {:ok, _} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner)

    assert {:ok, _} =
             RoleManagement.revoke_membership(c.credential, c.business, c.owner_membership)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)
  end

  test "membership reactivation restores no revoked roles", c do
    {:ok, r} =
      RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    assert {:ok, _} = RoleManagement.revoke_membership(c.credential, c.business, c.membership)
    assert {:ok, _} = RoleManagement.reactivate_membership(c.credential, c.business, c.membership)
    assert Repo.get!(RoleAssignment, r.id).status == :revoked
    assert {:error, :forbidden} = Authorization.authorize(c.target, :finance_manage, c.business)

    assert {:ok, fresh} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    assert fresh.id != r.id
  end

  test "ineligible accounts and archived businesses/shops denied", c do
    {:ok, _} = Accounts.set_user_status(c.target, :pending)

    assert {:error, :ineligible_target} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner)

    Repo.update!(change(c.business, status: :archived))

    assert {:error, :forbidden} =
             RoleManagement.revoke_membership(c.credential, c.business, c.membership)
  end

  test "cascade audit failure rolls back membership and grants together", c do
    {:ok, r} =
      RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    before = Repo.aggregate(AuditEvent, :count)

    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_cascade_audit_unavailable CHECK (action <> 'revoke_role') NOT VALID"
    )

    assert {:error, :persistence_failed} =
             RoleManagement.revoke_membership(c.credential, c.business, c.membership)

    assert Repo.get!(BusinessMembership, c.membership.id).status == :active
    assert Repo.get!(RoleAssignment, r.id).status == :active
    assert Repo.aggregate(AuditEvent, :count) == before
  end

  test "revocation audits each affected grant scope", c do
    {:ok, r} =
      RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    assert {:ok, _} = RoleManagement.revoke_membership(c.credential, c.business, c.membership)
    event = Repo.one!(from e in AuditEvent, where: e.action == :revoke_role)
    assert event.role_assignment_id == r.id and event.role == :business_manager
    assert event.actor_user_id == c.owner.id and event.target_user_id == c.target.id
  end

  test "stale session and Owner eligibility are rechecked", c do
    {:ok, _} = Accounts.set_user_status(c.owner, :suspended)

    assert {:error, :forbidden} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_owner)

    assert Repo.aggregate(RoleAssignment, :count) == 1
  end

  test "outer rollback rolls back both audit and mutation", c do
    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        RoleManagement.grant_role(
                          c.credential,
                          c.business,
                          c.membership,
                          :business_manager
                        )

               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "audit insertion failure rolls back the grant", c do
    # Transaction-local fault injection, no application bypass/config switch.
    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_audit_unavailable CHECK (business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             RoleManagement.grant_role(c.credential, c.business, c.membership, :business_manager)

    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 0
  end
end
