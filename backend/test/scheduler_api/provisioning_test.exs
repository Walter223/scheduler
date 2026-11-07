defmodule SchedulerApi.ProvisioningTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  alias SchedulerApi.{Accounts, Authorization, Catalog, Organizations, Provisioning}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Authorization.{AuditEvent, OwnerBootstrap, RoleManagement}
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Provisioning.{Credential, Intent}

  @now ~U[2026-11-06 12:00:00Z]

  setup do
    %{owner: active_user_fixture(), attrs: request()}
  end

  defp request do
    %{
      business: %{
        name: "Independent Detail",
        slug: "independent-#{System.unique_integer([:positive])}"
      },
      shop: %{name: "First Location", slug: "first", timezone: "America/New_York"}
    }
  end

  defp issue(c, opts \\ [now: @now]) do
    Provisioning.authorize_operator(
      c.owner.keycloak_issuer,
      c.owner.keycloak_subject,
      c.attrs,
      opts
    )
  end

  test "eligible explicit intent creates one independent tenant, membership, Owner and truthful audit",
       c do
    owner_before = Repo.get!(User, c.owner.id)
    assert {:ok, credential} = issue(c)
    assert {:ok, result} = Provisioning.provision(credential, now: @now)
    b = Repo.get!(Business, result.business_id)
    s = Repo.get!(Shop, result.shop_id)
    m = Repo.get!(BusinessMembership, result.membership_id)
    r = Repo.get!(RoleAssignment, result.role_assignment_id)
    e = Repo.get!(AuditEvent, result.audit_event_id)
    assert b.name == c.attrs.business.name and b.slug == c.attrs.business.slug
    assert b.status == :active
    assert s.business_id == b.id and s.timezone == "America/New_York" and s.status == :active
    assert s.name == "First Location" and s.slug == "first"
    assert m.user_id == c.owner.id and m.business_id == b.id and m.status == :active
    assert r.membership_id == m.id and r.business_id == b.id
    assert r.role == :business_owner and r.status == :active and is_nil(r.shop_id)
    assert e.source == :deployment_operator_command and e.action == :provision_business
    assert e.actor_user_id == nil and e.target_user_id == c.owner.id
    assert e.business_id == b.id and e.shop_id == s.id and e.membership_id == m.id
    assert e.role_assignment_id == r.id and e.role == :business_owner
    assert e.outcome == :applied and e.occurred_at == @now
    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Authorization.authorize(c.owner, :access_manage, b) == :ok
    assert Catalog.list_services(s) == [] and Catalog.list_services_with_prices(s) == []
    assert Repo.get!(User, c.owner.id) == owner_before
  end

  test "intent is a persisted independent random capability, not an ID or claims map", c do
    assert {:ok, a} = issue(c)
    assert {:ok, b} = issue(c)
    refute a == b
    refute inspect(a) =~ a.value
    assert {:ok, hash} = Credential.digest(a)
    i = Repo.get_by!(Intent, credential_hash: hash)
    assert byte_size(i.credential_hash) == 32 and i.credential_hash != a.value
    assert i.owner_id == c.owner.id and is_nil(i.completed_at)
    assert i.expires_at == DateTime.add(@now, 600)
    assert {:error, :invalid_intent} = Provisioning.provision(c.owner.id)
    assert {:error, :invalid_intent} = Provisioning.provision(%{user_id: c.owner.id})
    assert {:error, :invalid_intent} = Provisioning.provision(Credential.generate())
    assert {:error, :invalid_intent} = Provisioning.provision(%Credential{value: "invalid"})
  end

  test "same authorized request is idempotent even after intent deadline", c do
    {:ok, credential} = issue(c)
    assert {:ok, result} = Provisioning.provision(credential, now: @now)
    assert {:ok, ^result} = Provisioning.provision(credential, now: DateTime.add(@now, 601))
    assert Repo.aggregate(RoleAssignment, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 1
    assert Repo.aggregate(Shop, :count) == 2
  end

  test "unconsumed intent expires exactly at ten minutes", c do
    {:ok, credential} = issue(c)

    assert {:error, :expired_intent} =
             Provisioning.provision(credential, now: DateTime.add(@now, 600))

    assert {:error, :expired_intent} =
             Provisioning.provision(credential, now: DateTime.add(@now, 601))

    assert {:ok, _} = Provisioning.provision(credential, now: DateTime.add(@now, 599))
  end

  test "identity must match exact immutable pair, never email or stale account state", c do
    assert {:error, :ineligible_identity} =
             Provisioning.authorize_operator(c.owner.keycloak_issuer, c.owner.email, c.attrs)

    assert {:error, :ineligible_identity} =
             Provisioning.authorize_operator(
               c.owner.keycloak_issuer <> "/",
               c.owner.keycloak_subject,
               c.attrs
             )

    assert {:error, :ineligible_identity} = Provisioning.authorize_operator(nil, nil, c.attrs)

    for status <- [:pending, :suspended, :deactivated] do
      Repo.update!(change(Repo.get!(User, c.owner.id), status: status))
      assert {:error, :ineligible_identity} = issue(c)
      assert Repo.get!(User, c.owner.id).status == status
    end

    Repo.update!(change(Repo.get!(User, c.owner.id), status: :active, email_verified: false))
    assert {:error, :ineligible_identity} = issue(c)
    assert Repo.aggregate(Intent, :count) == 0
  end

  test "eligibility is rechecked at consumption and on completed retries", c do
    {:ok, credential} = issue(c)
    Repo.update!(change(c.owner, email_verified: false))
    assert {:error, :ineligible_identity} = Provisioning.provision(credential, now: @now)
    Repo.update!(change(Repo.get!(User, c.owner.id), email_verified: true))
    assert {:ok, _} = Provisioning.provision(credential, now: @now)
    {:ok, _} = Accounts.set_user_status(c.owner, :suspended)
    assert {:error, :ineligible_identity} = Provisioning.provision(credential, now: @now)
  end

  test "strict names, slugs, timezone and field allowlists", c do
    bad = [
      put_in(c.attrs, [:business, :name], "  "),
      put_in(c.attrs, [:business, :slug], "../existing"),
      put_in(c.attrs, [:business, :name], String.duplicate("a", 256)),
      put_in(c.attrs, [:shop, :name], ""),
      put_in(c.attrs, [:shop, :slug], "Invalid"),
      put_in(c.attrs, [:shop, :timezone], "Not/AZone"),
      put_in(c.attrs, [:shop, :timezone], "+05:00"),
      put_in(c.attrs, [:shop, :timezone], nil),
      Map.put(c.attrs, :owner_id, c.owner.id),
      Map.put(c.attrs, :business_id, Organizations.default_business!().id),
      update_in(c.attrs.business, &Map.put(&1, :status, :active)),
      update_in(c.attrs.shop, &Map.put(&1, :business_id, 1)),
      update_in(c.attrs.shop, &Map.put(&1, :role, :business_owner))
    ]

    for attrs <- bad, do: assert({:error, :invalid_input} = issue(%{c | attrs: attrs}))
    assert Repo.aggregate(Intent, :count) == 0
    assert {:error, :invalid_options} = issue(c, now: "invalid")

    assert {:error, :invalid_options} =
             Provisioning.provision(Credential.generate(), role: :business_owner)
  end

  test "existing name does not claim an existing business; conflicting slug never grants access",
       c do
    original = Organizations.default_business!()
    {:ok, conflict} = issue(%{c | attrs: put_in(c.attrs, [:business, :slug], original.slug)})
    assert {:error, :slug_unavailable} = Provisioning.provision(conflict, now: @now)
    assert Repo.aggregate(BusinessMembership, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 0
    {:ok, separate} = issue(%{c | attrs: put_in(c.attrs, [:business, :name], original.name)})
    assert {:ok, result} = Provisioning.provision(separate, now: @now)
    assert result.business_id != original.id
    assert Repo.get!(Business, original.id) == original
    assert Authorization.authorize(c.owner, :access_manage, original) != :ok
  end

  test "audit failure rolls back every provisioning write, leaving intent retryable", c do
    {:ok, credential} = issue(c)

    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_provision_audit_failure CHECK (action <> 'provision_business') NOT VALID"
    )

    assert {:error, :persistence_failed} = Provisioning.provision(credential, now: @now)
    assert Repo.aggregate(Business, :count) == 1
    assert Repo.aggregate(Shop, :count) == 1
    assert Repo.aggregate(BusinessMembership, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
    assert is_nil(Repo.one!(Intent).completed_at)

    Repo.query!(
      "ALTER TABLE authorization_audit_events DROP CONSTRAINT test_provision_audit_failure"
    )

    assert {:ok, _} = Provisioning.provision(credential, now: @now)
  end

  test "retry cannot restore revoked access or bypass historical Owner bootstrap protection", c do
    {:ok, credential} = issue(c)
    {:ok, result} = Provisioning.provision(credential, now: @now)
    b = Repo.get!(Business, result.business_id)

    assert {:error, :existing_owner_history} =
             OwnerBootstrap.run(b.id, c.owner.keycloak_issuer, c.owner.keycloak_subject)

    {:ok, _, session} = Accounts.create_session(c.owner)
    m = Repo.get!(BusinessMembership, result.membership_id)
    # Normal management still refuses removing the last eligible Owner.
    assert {:error, :last_owner} = RoleManagement.revoke_membership(session, b, m)
    {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(m)
    assert {:ok, ^result} = Provisioning.provision(credential, now: @now)
    assert Repo.get!(BusinessMembership, m.id).status == :revoked
    assert Repo.get!(RoleAssignment, result.role_assignment_id).status == :revoked
    assert Authorization.authorize(c.owner, :access_manage, b) != :ok
  end

  test "existing Magnum tenant, catalog and appointment remain byte-for-byte unchanged", c do
    price = service_price_fixture()
    {:ok, appointment} = SchedulerApi.Appointments.create_appointment(booking_attrs(price))
    b = Organizations.default_business!()
    s = Organizations.default_shop!()
    catalog = Catalog.list_services_with_prices(s)
    {:ok, credential} = issue(c)
    {:ok, result} = Provisioning.provision(credential, now: @now)
    assert Organizations.default_business!() == b and Organizations.default_shop!() == s
    assert Catalog.list_services_with_prices(s) == catalog
    assert Repo.get!(SchedulerApi.Appointments.Appointment, appointment.id) == appointment
    assert Repo.get!(SchedulerApi.Catalog.ServicePrice, price.id) == price
    assert Catalog.list_services_with_prices(Repo.get!(Shop, result.shop_id)) == []

    assert Repo.aggregate(
             from(a in SchedulerApi.Appointments.Appointment,
               where: a.business_id == ^result.business_id
             ),
             :count
           ) == 0
  end

  test "existing ownership and membership remain independent when an Owner creates another tenant",
       c do
    original = Organizations.default_business!()

    {:ok, old_result} =
      OwnerBootstrap.run(original.id, c.owner.keycloak_issuer, c.owner.keycloak_subject,
        apply: true
      )

    old_membership = Repo.get!(BusinessMembership, old_result.membership_id)
    old_grant = Repo.get!(RoleAssignment, old_result.role_assignment_id)
    old_audit = Repo.one!(AuditEvent)
    {:ok, old_session, _} = Accounts.create_session(c.owner)
    {:ok, credential} = issue(c)
    {:ok, result} = Provisioning.provision(credential, now: @now)
    assert result.business_id != original.id
    assert Repo.get!(BusinessMembership, old_membership.id) == old_membership
    assert Repo.get!(RoleAssignment, old_grant.id) == old_grant
    assert Repo.get!(AuditEvent, old_audit.id) == old_audit
    assert Repo.get!(SchedulerApi.Accounts.WebSession, old_session.id) == old_session
    assert Authorization.authorize(c.owner, :access_manage, original) == :ok

    assert Authorization.authorize(
             c.owner,
             :access_manage,
             Repo.get!(Business, result.business_id)
           ) == :ok

    assert {:error, :existing_owner_history} =
             OwnerBootstrap.run(original.id, c.owner.keycloak_issuer, c.owner.keycloak_subject)
  end

  test "database independently enforces hash uniqueness, completion and tenant integrity", c do
    {:ok, credential} = issue(c)
    i = Repo.one!(Intent)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%{i | id: nil}, mode: :savepoint)
    end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.update!(change(i, completed_at: @now), mode: :savepoint)
    end

    {:ok, result} = Provisioning.provision(credential, now: @now)
    i = Repo.get!(Intent, i.id)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.update!(change(i, shop_id: Organizations.default_shop!().id), mode: :savepoint)
    end

    assert Repo.get!(Intent, i.id).business_id == result.business_id
  end
end
