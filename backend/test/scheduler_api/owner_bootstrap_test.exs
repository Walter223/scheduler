defmodule SchedulerApi.OwnerBootstrapTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Authorization.{OwnerBootstrap, AuditEvent}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}

  setup do
    b =
      Repo.insert!(%Business{
        name: "Bootstrap",
        slug: "bootstrap-#{System.unique_integer([:positive])}"
      })

    u = active_user_fixture()
    %{b: b, u: u}
  end

  defp run(c, opts \\ []),
    do: OwnerBootstrap.run(c.b.id, c.u.keycloak_issuer, c.u.keycloak_subject, opts)

  test "default dry-run and task invocation write no rows or audit", c do
    before = Repo.get!(User, c.u.id)
    assert {:ok, %{mode: :dry_run, membership: :create}} = run(c)
    old = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(old) end)

    Mix.Tasks.Magnum.BootstrapOwner.run([
      "--business-id",
      to_string(c.b.id),
      "--issuer",
      c.u.keycloak_issuer,
      "--subject",
      c.u.keycloak_subject
    ])

    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "DRY RUN"
    assert Repo.aggregate(BusinessMembership, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
    assert Repo.get!(User, c.u.id) == before
  end

  test "apply creates scoped membership, Owner and truthful operator-source audit", c do
    assert {:ok, result} = run(c, apply: true)
    role = Repo.get!(RoleAssignment, result.role_assignment_id)
    assert role.role == :business_owner and role.business_id == c.b.id and is_nil(role.shop_id)
    e = Repo.one!(AuditEvent)
    assert e.source == :deployment_operator_command and e.action == :bootstrap_owner
    assert is_nil(e.actor_user_id) and is_nil(e.shop_id)

    assert e.target_user_id == c.u.id and e.role_assignment_id == role.id and
             e.outcome == :applied

    assert {:error, :existing_owner_history} = run(c, apply: true)
    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 2
  end

  test "exact issuer/subject required; matching email never identifies a user", c do
    assert {:error, :invalid_identity} =
             OwnerBootstrap.run(c.b.id, c.u.keycloak_issuer, c.u.email, apply: true)

    assert {:error, :invalid_identity} =
             OwnerBootstrap.run(c.b.id, c.u.keycloak_issuer <> "/", c.u.keycloak_subject)

    assert {:error, :invalid_identity} =
             OwnerBootstrap.run(c.b.id, c.u.keycloak_issuer, String.upcase(c.u.keycloak_subject))

    assert {:error, :invalid_business} =
             OwnerBootstrap.run(-1, c.u.keycloak_issuer, c.u.keycloak_subject, apply: true)

    assert Repo.aggregate(RoleAssignment, :count) == 0
  end

  test "inactive/unverified identities and archived businesses fail without activation", c do
    for status <- [:pending, :suspended, :deactivated] do
      Repo.update!(change(c.u, status: status))
      assert {:error, :ineligible_target} = run(c, apply: true)
      assert Repo.get!(User, c.u.id).status == status
    end

    Repo.update!(change(c.u, status: :active, email_verified: false))
    assert {:error, :ineligible_target} = run(c)
    Repo.update!(change(c.u, status: :active, email_verified: true))
    Repo.update!(change(c.b, status: :archived))
    assert {:error, :inactive_business} = run(c)
    assert Repo.aggregate(RoleAssignment, :count) == 0
  end

  test "historical ownership prohibits bootstrap even when revoked", c do
    m = Repo.insert!(%BusinessMembership{user_id: c.u.id, business_id: c.b.id})
    t = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%RoleAssignment{
      membership_id: m.id,
      business_id: c.b.id,
      role: :business_owner,
      status: :revoked,
      revoked_at: t,
      revocation_reason: :manual,
      inserted_at: t,
      updated_at: t
    })

    assert {:error, :existing_owner_history} = run(c, apply: true)
  end

  test "reuse active membership; never reactivate a revoked membership", c do
    m = Repo.insert!(%BusinessMembership{user_id: c.u.id, business_id: c.b.id})
    {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(m)
    assert {:error, :inactive_membership} = run(c, apply: true)
    {:ok, _} = SchedulerApi.Organizations.Memberships.reactivate(m)
    assert {:ok, %{membership_id: id}} = run(c, apply: true)
    assert id == m.id
  end

  test "audit failure rolls back membership and Owner insertion", c do
    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_bootstrap_audit_failure CHECK (action <> 'bootstrap_owner') NOT VALID"
    )

    assert {:error, :persistence_failed} = run(c, apply: true)
    assert Repo.aggregate(BusinessMembership, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "unrelated tenants, identity and existing audit events remain unchanged", c do
    other = Repo.insert!(%Business{name: "Other", slug: "other"})
    m = Repo.insert!(%BusinessMembership{user_id: c.u.id, business_id: other.id})

    r =
      Repo.insert!(%RoleAssignment{
        membership_id: m.id,
        business_id: other.id,
        role: :business_owner
      })

    user = Repo.get!(User, c.u.id)
    assert {:ok, _} = run(c, apply: true)
    assert Repo.get!(Business, other.id) == other
    assert Repo.get!(BusinessMembership, m.id) == m
    assert Repo.get!(RoleAssignment, r.id) == r
    assert Repo.get!(User, c.u.id) == user
  end

  test "command rejects missing, unknown and duplicate flags; apply is opt-in" do
    task = Mix.Tasks.Magnum.BootstrapOwner

    assert {:ok, 1, "issuer", "subject", false} =
             task.parse(["--business-id", "1", "--issuer", "issuer", "--subject", "subject"])

    for args <- [
          [],
          ["--business-id", "1", "--email", "someone"],
          ["--apply"],
          ["--operator", "claimed-human"]
        ] do
      assert :error = task.parse(args)
    end

    assert {:error, :invalid_options} =
             OwnerBootstrap.run(1, "issuer", "subject", operator: "claimed-human")
  end
end
