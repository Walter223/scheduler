defmodule SchedulerApi.OnboardingTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  alias SchedulerApi.{Accounts, Provisioning}
  alias SchedulerApi.Accounts.{User, WebSession}
  alias SchedulerApi.Authentication.Credential
  alias SchedulerApi.Provisioning.Onboarding
  alias SchedulerApi.Provisioning.Onboarding.Proof
  alias SchedulerApi.Authorization.AuditEvent
  alias SchedulerApi.Organizations.{Business, BusinessMembership}
  @now ~U[2026-11-06 10:00:00Z]
  setup do
    user = user_fixture()
    binding = Credential.generate() |> Credential.reveal()
    {:ok, {:onboarding, token}} = Onboarding.issue_after_oidc(user, binding, now: @now)
    raw = Credential.reveal(token)
    {:ok, %{csrf_token: csrf}} = Onboarding.status(raw, binding, now: @now)

    %{
      user: user,
      token: raw,
      binding: binding,
      csrf: csrf,
      attrs: %{
        business: %{name: "Signup", slug: "signup-#{System.unique_integer([:positive])}"},
        shop: %{name: "Main", slug: "main", timezone: "America/Denver"}
      }
    }
  end

  defp complete(c, attrs \\ nil, now \\ @now),
    do: Onboarding.complete(c.token, c.binding, c.csrf, attrs || c.attrs, now: now)

  test "pending verified user activates only atomically with its own independent tenant", c do
    assert Repo.get!(User, c.user.id).status == :pending
    assert {:ok, r} = complete(c)
    assert Repo.get!(User, c.user.id).status == :active
    assert Repo.get!(BusinessMembership, r["membership_id"]).user_id == c.user.id
    e = Repo.get!(AuditEvent, r["audit_event_id"])
    assert e.source == :self_service_signup and e.actor_user_id == c.user.id
    assert e.activated_pending_account
    assert Repo.aggregate(WebSession, :count) == 0
    assert SchedulerApi.Organizations.default_business!().id != r["business_id"]
  end

  test "active identity can create a new tenant without duplicate activation", c do
    {:ok, _} = Accounts.set_user_status(c.user, :active)
    {:ok, r} = complete(c)
    refute Repo.get!(AuditEvent, r["audit_event_id"]).activated_pending_account
  end

  test "cross-browser proof theft, forged proofs and cross-proof CSRF fail", c do
    b = Credential.generate() |> Credential.reveal()
    assert {:error, :invalid_proof} = complete(%{c | binding: b})
    assert {:error, :invalid_proof} = complete(%{c | token: b})
    assert {:error, :invalid_csrf} = complete(%{c | csrf: "invalid"})
    {:ok, {:onboarding, t}} = Onboarding.issue_after_oidc(active_user_fixture(), b, now: @now)
    {:ok, %{csrf_token: csrf}} = Onboarding.status(Credential.reveal(t), b, now: @now)
    assert {:error, :invalid_csrf} = complete(%{c | csrf: csrf})
  end

  test "expiry equality, identical retries and changed-payload replay", c do
    assert {:error, :invalid_proof} = complete(c, nil, DateTime.add(@now, 600))
    assert {:ok, r} = complete(c)
    assert {:ok, ^r} = complete(c)
    assert {:error, :replayed_proof} = complete(c, put_in(c.attrs, [:business, :name], "Changed"))
    assert Repo.aggregate(AuditEvent, :count) == 1
  end

  test "suspended, deactivated and unverified accounts cannot issue or consume", c do
    for attrs <- [
          [status: :suspended],
          [status: :deactivated],
          [status: :pending, email_verified: false]
        ] do
      user = Repo.get!(User, c.user.id) |> change(attrs) |> Repo.update!()
      assert {:error, :ineligible_identity} = complete(c)

      assert {:error, :ineligible_identity} =
               Onboarding.issue_after_oidc(user, c.binding, now: @now)
    end
  end

  test "slug collision and ownership injection never activate or consume", c do
    assert {:error, :slug_unavailable} =
             complete(c, put_in(c.attrs, [:business, :slug], "magnum-detailing"))

    assert {:error, :invalid_input} = complete(c, Map.put(c.attrs, :owner_id, c.user.id))
    assert is_nil(Repo.one!(Proof).consumed_at)
    assert Repo.get!(User, c.user.id).status == :pending
    assert Repo.aggregate(Business, :count) == 1
    assert {:ok, _} = complete(c)
  end

  test "audit failure rolls activation, consumption and tenant writes back", c do
    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_signup_audit_failure CHECK (source <> 'self_service_signup') NOT VALID"
    )

    assert {:error, :operation_unavailable} = complete(c)
    assert Repo.get!(User, c.user.id).status == :pending
    assert is_nil(Repo.one!(Proof).consumed_at)
    assert Repo.aggregate(BusinessMembership, :count) == 0

    Repo.query!(
      "ALTER TABLE authorization_audit_events DROP CONSTRAINT test_signup_audit_failure"
    )

    assert {:ok, _} = complete(c)
  end

  test "IP/identity budgets retain independent browser attempts", c do
    for _ <- 1..20, do: assert({:ok, :ok} = Onboarding.attempt("test-ip", now: @now))
    assert {:error, :rate_limited} = Onboarding.attempt("test-ip", now: @now)

    for _ <- 1..4,
        do: assert({:ok, _} = Onboarding.issue_after_oidc(c.user, c.binding, now: @now))

    assert {:error, :rate_limited} = Onboarding.issue_after_oidc(c.user, c.binding, now: @now)
    assert {:ok, _} = complete(c)
  end

  test "daily budget and operator capability isolation", c do
    assert {:ok, _} = complete(c)
    {:ok, {:onboarding, t}} = Onboarding.issue_after_oidc(c.user, c.binding, now: @now)
    token = Credential.reveal(t)
    {:ok, %{csrf_token: csrf}} = Onboarding.status(token, c.binding, now: @now)
    assert {:error, :rate_limited} = complete(%{c | token: token, csrf: csrf})
    user = Repo.get!(User, c.user.id)

    {:ok, op} =
      Provisioning.authorize_operator(user.keycloak_issuer, user.keycloak_subject, c.attrs,
        now: @now
      )

    assert {:error, :invalid_proof} = complete(%{c | token: op.value})
  end
end
