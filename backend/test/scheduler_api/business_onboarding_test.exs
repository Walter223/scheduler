defmodule SchedulerApi.BusinessOnboardingTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{BusinessOnboarding, Accounts}
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.BusinessOnboarding.Draft
  alias SchedulerApi.Organizations.{Business, RoleAssignment}

  setup do
    shop = shop_fixture()
    user = active_user_fixture()
    grant_fixture(user, shop, :business_owner)
    {_s, t} = session_fixture(user)
    %{shop: shop, user: user, token: %SessionCredential{value: t}, business: shop.business_id}
  end

  defp attrs(d, changes \\ %{}),
    do:
      Map.merge(
        %{
          "revision" => d["revision"],
          "request_id" => Ecto.UUID.generate(),
          "state" => d["state"],
          "proposal" => d["proposal"]
        },
        changes
      )

  test "start/resume saves proposals but preserves existing business/shop records", c do
    b = Repo.get!(Business, c.business)
    assert {:error, :not_started} = BusinessOnboarding.get(c.token, c.business)
    assert {:ok, d} = BusinessOnboarding.start(c.token, c.business)
    assert d["state"] == "provisioning_complete"
    assert {:ok, ^d} = BusinessOnboarding.start(c.token, c.business)
    assert {:ok, ^d} = BusinessOnboarding.get(c.token, c.business)
    assert Repo.aggregate(Draft, :count) == 1

    p =
      put_in(d["proposal"], ["employees"], [
        %{"name" => "Proposed Manager", "intended_role" => "business_manager"}
      ])

    assert {:ok, saved} =
             BusinessOnboarding.update(c.token, c.business, attrs(d, %{"proposal" => p}))

    assert saved["revision"] == 1
    {_s, newtoken} = session_fixture(c.user)
    assert {:ok, ^saved} = BusinessOnboarding.get(%SessionCredential{value: newtoken}, c.business)
    assert Repo.get!(Business, c.business) == b
    assert Repo.get!(SchedulerApi.Organizations.Shop, c.shop.id) == c.shop
    assert Repo.aggregate(SchedulerApi.Employment.EmploymentRecord, :count) == 0
    assert Repo.aggregate(RoleAssignment, :count) == 1
  end

  test "only current eligible Owners; no cross-tenant, stale user or revoked grant access", c do
    {:ok, _} = BusinessOnboarding.start(c.token, c.business)

    for role <- [:business_manager, :shop_manager, :employee] do
      u = active_user_fixture()
      grant_fixture(u, c.shop, role)
      {_s, t} = session_fixture(u)

      assert {:error, :forbidden} =
               BusinessOnboarding.get(%SessionCredential{value: t}, c.business)
    end

    other = other_business_price_fixture().shop
    assert {:error, :forbidden} = BusinessOnboarding.get(c.token, other.business_id)

    Repo.update_all(
      from(r in RoleAssignment,
        where: r.business_id == ^c.business and r.role == :business_owner
      ),
      set: [
        status: "revoked",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: "manual"
      ]
    )

    assert {:error, :forbidden} = BusinessOnboarding.get(c.token, c.business)
    {:ok, _} = Accounts.set_user_status(c.user, :suspended)
    assert {:error, :invalid_session} = BusinessOnboarding.get(c.token, c.business)
  end

  test "deterministic transitions and explicit review confirmation", c do
    {:ok, d} = BusinessOnboarding.start(c.token, c.business)

    assert {:error, :invalid_transition} =
             BusinessOnboarding.update(c.token, c.business, attrs(d, %{"state" => "review"}))

    proposal =
      put_in(d["proposal"], ["services"], [
        %{"name" => "Detail", "duration_minutes" => 60, "price_cents" => 12000}
      ])

    final =
      Enum.reduce(tl(BusinessOnboarding.states()), d, fn state, prev ->
        {:ok, next} =
          BusinessOnboarding.update(
            c.token,
            c.business,
            attrs(prev, %{"state" => state, "proposal" => proposal, "confirm_review" => true})
          )

        next
      end)

    assert final["state"] == "completed"
    assert final["readiness"]["published"] == false

    assert {:error, :invalid_transition} =
             BusinessOnboarding.update(c.token, c.business, attrs(final))
  end

  test "revision conflicts, idempotency and rejected payload changes", c do
    {:ok, d} = BusinessOnboarding.start(c.token, c.business)
    a = attrs(d)
    assert {:ok, r} = BusinessOnboarding.update(c.token, c.business, a)
    assert {:ok, ^r} = BusinessOnboarding.update(c.token, c.business, a)

    assert {:error, :request_conflict} =
             BusinessOnboarding.update(c.token, c.business, Map.put(a, "state", "locations"))

    assert {:error, :revision_conflict} = BusinessOnboarding.update(c.token, c.business, attrs(d))

    for p <- [
          Map.put(d["proposal"], "password", "secret"),
          put_in(d["proposal"], ["employees"], [%{"name" => "Bad", "role" => "business_owner"}])
        ] do
      assert {:error, :invalid_input} =
               BusinessOnboarding.update(c.token, c.business, attrs(r, %{"proposal" => p}))
    end

    assert Repo.aggregate("business_onboarding_events", :count) == 2
  end

  test "audit failures roll back state and receipts", c do
    {:ok, d} = BusinessOnboarding.start(c.token, c.business)

    Repo.query!(
      "ALTER TABLE business_onboarding_events ADD CONSTRAINT test_onboarding_audit CHECK (revision=0) NOT VALID"
    )

    assert {:error, :operation_unavailable} =
             BusinessOnboarding.update(c.token, c.business, attrs(d))

    assert {:ok, ^d} = BusinessOnboarding.get(c.token, c.business)
    assert Repo.aggregate("business_onboarding_receipts", :count) == 0
  end
end
