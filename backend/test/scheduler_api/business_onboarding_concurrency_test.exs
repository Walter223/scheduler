defmodule SchedulerApi.BusinessOnboardingConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Repo, BusinessOnboarding}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment, Shop}
  alias SchedulerApi.Accounts.{WebSession, SessionCredential}
  alias SchedulerApi.BusinessOnboarding.Draft

  test "independent connections serialize start and reject a stale concurrent edit" do
    {b, u, token} =
      Sandbox.unboxed_run(Repo, fn ->
        b =
          Repo.insert!(%Business{
            name: "Draft Race",
            slug: "draft-race-#{System.unique_integer([:positive])}"
          })

        shop = shop_fixture(%{business_id: b.id})
        u = active_user_fixture()
        grant_fixture(u, shop, :business_owner)
        {_s, t} = session_fixture(u)
        {b, u, %SessionCredential{value: t}}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = Repo.all(from d in Draft, where: d.business_id == ^b.id, select: d.id)
        Repo.delete_all(from r in "business_onboarding_receipts", where: r.draft_id in ^ids)
        Repo.delete_all(from e in "business_onboarding_events", where: e.draft_id in ^ids)
        Repo.delete_all(from d in Draft, where: d.id in ^ids)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^b.id)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^b.id)
        Repo.delete_all(from s in Shop, where: s.business_id == ^b.id)
        Repo.delete!(b)
        Repo.delete_all(from s in WebSession, where: s.user_id == ^u.id)
        Repo.delete!(u)
      end)
    end)

    [{:ok, d}, {:ok, same}] = race(fn -> BusinessOnboarding.start(token, b.id) end)
    assert same == d

    results =
      race(fn ->
        BusinessOnboarding.update(token, b.id, %{
          "revision" => 0,
          "request_id" => Ecto.UUID.generate(),
          "state" => "locations",
          "proposal" =>
            Map.merge(d["proposal"], %{
              "defaults" => %{"timezone" => "America/Denver", "operating_model" => "in_shop"},
              "employees" => [
                %{
                  "version" => 2,
                  "key" => "staff",
                  "name" => "Concurrent Staff",
                  "email" => "race@example.invalid",
                  "classification" => "detailer",
                  "location_keys" => ["one", "two"],
                  "responsibilities" => %{
                    "business_management" => false,
                    "shop_management_keys" => []
                  },
                  "access_roles" => [%{"role" => "employee", "location_keys" => ["one", "two"]}]
                }
              ],
              "catalog" => %{
                "version" => 1,
                "currency" => "USD",
                "vehicle_categories" => [%{"key" => "car", "name" => "Custom car"}]
              },
              "services" => [
                %{
                  "version" => 2,
                  "key" => "wash",
                  "name" => "Custom wash",
                  "description" => "Draft wash",
                  "duration_minutes" => 60,
                  "status" => "planned",
                  "delivery_mode" => "in_shop",
                  "location_keys" => ["one", "two"],
                  "prices" => [%{"category_key" => "car", "price_cents" => 12345}],
                  "overrides" => []
                }
              ],
              "locations" => [
                %{"key" => "one", "name" => "First", "address" => "1 Fictional Way"},
                %{"key" => "two", "name" => "Second", "address" => "2 Fictional Way"}
              ]
            })
        })
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :revision_conflict})) == 1
  end

  defp race(fun) do
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

            fun.()
          end)
        end)
      end

    assert_receive {:ready, a, pa}, 5000
    assert_receive {:ready, b, pb}, 5000
    refute pa == pb
    send(a, :go)
    send(b, :go)
    Enum.map(tasks, &Task.await(&1, 10000))
  end
end
