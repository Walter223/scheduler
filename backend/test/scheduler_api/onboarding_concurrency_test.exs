defmodule SchedulerApi.OnboardingConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.Repo
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Authentication.Credential
  alias SchedulerApi.Provisioning.{Onboarding, Intent}
  alias SchedulerApi.Provisioning.Onboarding.Proof
  alias SchedulerApi.Authorization.AuditEvent
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  @now ~U[2026-11-06 12:00:00Z]

  test "same proof is atomic under independent connections and separate proofs cannot bypass daily budget" do
    {user, binding, token, csrf, attrs} =
      Sandbox.unboxed_run(Repo, fn ->
        u = user_fixture()
        b = Credential.generate() |> Credential.reveal()
        {:ok, {:onboarding, t}} = Onboarding.issue_after_oidc(u, b, now: @now)
        t = Credential.reveal(t)
        {:ok, %{csrf_token: csrf}} = Onboarding.status(t, b, now: @now)

        {u, b, t, csrf,
         %{
           business: %{
             name: "Concurrent Signup",
             slug: "signup-race-#{System.unique_integer([:positive])}"
           },
           shop: %{name: "Main", slug: "main", timezone: "America/Denver"}
         }}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = Repo.all(from i in Intent, where: i.owner_id == ^user.id, select: i.business_id)
        Repo.delete_all(from p in Proof, where: p.user_id == ^user.id)
        Repo.delete_all(from i in Intent, where: i.owner_id == ^user.id)
        Repo.delete_all(from e in AuditEvent, where: e.business_id in ^ids)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id in ^ids)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id in ^ids)
        Repo.delete_all(from s in Shop, where: s.business_id in ^ids)
        Repo.delete_all(from b in Business, where: b.id in ^ids)

        for kind <- ["proof", "creation"] do
          key = :crypto.hash(:sha256, kind <> ":" <> to_string(user.id))
          Repo.delete_all(from l in "signup_limits", where: l.key == ^key)
        end

        Repo.delete!(Repo.get!(User, user.id))
      end)
    end)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), pid})

            receive do
              :go -> :ok
            after
              5000 -> raise "Missing barrier"
            end

            Onboarding.complete(token, binding, csrf, attrs, now: @now)
          end)
        end)
      end

    assert_receive {:ready, a, pa}, 5000
    assert_receive {:ready, b, pb}, 5000
    refute pa == pb
    send(a, :go)
    send(b, :go)
    [first, second] = Enum.map(tasks, &Task.await(&1, 10000))
    assert {:ok, r} = first
    assert second == first

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(e in AuditEvent, where: e.business_id == ^r["business_id"]),
               :count
             ) == 1

      {:ok, {:onboarding, t}} = Onboarding.issue_after_oidc(user, binding, now: @now)
      t = Credential.reveal(t)
      {:ok, %{csrf_token: c}} = Onboarding.status(t, binding, now: @now)
      assert {:error, :rate_limited} = Onboarding.complete(t, binding, c, attrs, now: @now)
    end)
  end
end
