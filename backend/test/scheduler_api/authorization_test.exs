defmodule SchedulerApi.AuthorizationTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.AccountsFixtures
  alias SchedulerApi.{Authorization, Accounts}
  alias SchedulerApi.Accounts.User

  alias SchedulerApi.Organizations.{
    Business,
    Shop,
    BusinessMembership,
    RoleAssignment,
    Memberships
  }

  setup do
    user = active_user_fixture()
    a = business("a")
    b = business("b")
    %{user: user, a: a, b: b, a1: shop(a, "one"), a2: shop(a, "two"), b1: shop(b, "one")}
  end

  defp business(slug),
    do: Repo.insert!(%Business{name: slug, slug: "#{slug}-#{System.unique_integer([:positive])}"})

  defp shop(b, slug),
    do: Repo.insert!(%Shop{business_id: b.id, name: slug, slug: slug, timezone: "America/Denver"})

  defp grant(user, b, role, s \\ nil) do
    m =
      Repo.get_by(BusinessMembership, user_id: user.id, business_id: b.id) ||
        Repo.insert!(%BusinessMembership{user_id: user.id, business_id: b.id})

    r =
      Repo.insert!(%RoleAssignment{
        membership_id: m.id,
        business_id: b.id,
        role: role,
        shop_id: s && s.id
      })

    {m, r}
  end

  test "owner is business-wide but never cross-tenant", c do
    grant(c.user, c.a, :business_owner)
    assert :ok = Authorization.authorize(c.user, :business_manage, c.a)
    assert :ok = Authorization.authorize(c.user, :compensation_write, c.a)

    for s <- [c.a1, c.a2],
        do: assert(:ok == Authorization.authorize(c.user, :appointments_read, s))

    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.b1)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :access_manage, c.b)

    assert Repo.all(Authorization.authorized_shop_ids_query(c.user, :appointments_read))
           |> Enum.map(& &1.id)
           |> Enum.sort() == Enum.sort([c.a1.id, c.a2.id])
  end

  test "HR finance does not imply operations or role management", c do
    grant(c.user, c.a, :business_manager)

    for action <- [
          :employment_manage,
          :compensation_read,
          :compensation_write,
          :payroll_manage,
          :finance_manage
        ] do
      assert :ok = Authorization.authorize(c.user, action, c.a)
    end

    assert {:error, :forbidden} = Authorization.authorize(c.user, :access_manage, c.a)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
    assert Repo.all(Authorization.authorized_shop_ids_query(c.user, :appointments_read)) == []
  end

  test "shop manager only operates explicit shops; pay and personal data remain unimplemented",
       c do
    grant(c.user, c.a, :shop_manager, c.a1)
    assert :ok = Authorization.authorize(c.user, :appointments_manage, c.a1)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_manage, c.a2)

    for action <- [
          :compensation_read,
          :compensation_write,
          :payroll_manage,
          :assigned_employee_contact_read,
          :assigned_employee_compensation_read
        ] do
      assert {:error, :forbidden} = Authorization.authorize(c.user, action, c.a1)
    end

    grant(c.user, c.a, :shop_manager, c.a2)
    assert :ok = Authorization.authorize(c.user, :schedule_manage, c.a2)
  end

  test "multiple grants never mix business permissions and shop scope", c do
    grant(c.user, c.a, :business_manager)
    grant(c.user, c.b, :shop_manager, c.b1)
    grant(c.user, c.a, :employee, c.a1)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :compensation_write, c.b)
    assert :ok = Authorization.authorize(c.user, :appointments_read, c.b1)
    assert :ok = Authorization.authorize(c.user, :compensation_write, c.a)
  end

  test "employee self/assigned actions require records, never broad shop fallback", c do
    grant(c.user, c.a, :employee, c.a1)

    for action <- [
          :appointments_read,
          :customers_manage,
          :jobs_assigned_read,
          :employment_own_read,
          :schedule_own_read
        ],
        target <- [c.a, c.a1, %{business_id: c.a.id, user_id: c.user.id}] do
      assert {:error, :forbidden} = Authorization.authorize(c.user, action, target)
    end
  end

  test "no grant, unknown action and unverifiable targets are denied", c do
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
    grant(c.user, c.a, :business_owner)

    for action <- [:god_mode, :platform_admin, :unknown, "appointments_read", nil],
        do: assert({:error, :forbidden} == Authorization.authorize(c.user, action, c.a1))

    for target <- [
          nil,
          %{business_id: c.a.id, shop_id: c.a1.id},
          %Shop{id: -1},
          %Business{id: -1},
          %SchedulerApi.Appointments.Appointment{id: -1}
        ] do
      assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, target)
    end

    assert {:error, :forbidden} = Authorization.authorize(%User{id: -1}, :business_manage, c.a)
  end

  test "persisted eligibility overrides stale structs for every account status", c do
    grant(c.user, c.a, :business_owner)

    for status <- [:pending, :suspended, :deactivated] do
      {:ok, _} = Accounts.set_user_status(c.user, status)
      assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
    end

    {:ok, _} = Accounts.set_user_status(c.user, :active)
    Repo.update_all(from(u in User, where: u.id == ^c.user.id), set: [email_verified: false])
    assert {:error, :forbidden} = Authorization.authorize(c.user, :business_manage, c.a)
  end

  test "membership revoke/reactivate and individual grant revoke affect next query", c do
    {m, r} = grant(c.user, c.a, :business_owner)
    query = Authorization.authorized_shop_ids_query(c.user, :appointments_read)
    assert Repo.all(query) != []
    {:ok, _} = Memberships.revoke(m)
    assert Repo.all(query) == []
    {:ok, _} = Memberships.reactivate(m)
    assert Repo.all(query) == []
    assert Repo.get!(RoleAssignment, r.id).status == :revoked
    {_m, new} = grant(c.user, c.a, :shop_manager, c.a1)
    assert :ok = Authorization.authorize(c.user, :appointments_read, c.a1)

    Repo.update!(
      change(new,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
  end

  test "appointment ownership is reloaded, not trusted from a supplied struct", c do
    price = SchedulerApi.CatalogFixtures.service_price_fixture()

    {:ok, appointment} =
      SchedulerApi.Appointments.create_appointment(
        SchedulerApi.AppointmentsFixtures.booking_attrs(price)
      )

    grant(c.user, c.a, :business_owner)
    spoofed = %{appointment | business_id: c.a.id, shop_id: c.a1.id}
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, spoofed)
    business = Repo.get!(Business, appointment.business_id)
    shop = Repo.get!(Shop, appointment.shop_id)
    grant(c.user, business, :shop_manager, shop)
    assert :ok = Authorization.authorize(c.user, :appointments_read, spoofed)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :customers_manage, appointment)
    Repo.update!(change(shop, status: :archived))
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, appointment)
  end

  test "archived tenants and spoofed ownership never authorize", c do
    grant(c.user, c.a, :business_owner)

    assert {:error, :forbidden} =
             Authorization.authorize(c.user, :appointments_read, %{
               c.b1
               | business_id: c.a.id,
                 status: :active
             })

    Repo.update!(change(c.a1, status: :archived))
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a1)
    Repo.update!(change(c.a, status: :archived))
    assert {:error, :forbidden} = Authorization.authorize(c.user, :business_manage, c.a)
    assert {:error, :forbidden} = Authorization.authorize(c.user, :appointments_read, c.a2)
  end
end
