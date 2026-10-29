defmodule SchedulerApi.MembershipConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.Repo
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}

  test "independent connections reject concurrent duplicate NULL and shop grants" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    {user, business, shop, membership} =
      Sandbox.unboxed_run(Repo, fn ->
        user = user_fixture()

        b =
          Repo.insert!(%Business{
            name: "Race",
            slug: "race-#{System.unique_integer([:positive])}"
          })

        s =
          Repo.insert!(%Shop{
            business_id: b.id,
            name: "Race",
            slug: "race",
            timezone: "America/Denver"
          })

        m = Repo.insert!(%BusinessMembership{user_id: user.id, business_id: b.id})
        {user, b, s, m}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in RoleAssignment, where: r.membership_id == ^membership.id)
        Repo.delete!(membership)
        Repo.delete!(shop)
        Repo.delete!(business)
        Repo.delete!(user)
      end)
    end)

    for {role, shop_id} <- [{"business_owner", nil}, {"employee", shop.id}], _ <- 1..3 do
      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), pid})

              receive do
                :go -> :ok
              after
                5000 -> raise "Missing barrier"
              end

              Repo.query(
                "INSERT INTO role_assignments(membership_id,business_id,shop_id,role,inserted_at,updated_at) VALUES($1,$2,$3,$4,timezone('UTC',now()),timezone('UTC',now())) RETURNING id",
                [membership.id, business.id, shop_id, role]
              )
            end)
          end)
        end

      assert_receive {:ready, first, a}, 5000
      assert_receive {:ready, second, b}, 5000
      refute a == b
      send(first, :go)
      send(second, :go)
      results = Enum.map(tasks, &Task.await(&1, 5000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}, &1)
             ) == 1

      Sandbox.unboxed_run(Repo, fn ->
        # Keep revoked rows as history while allowing the next iteration's new grant.
        Repo.query!(
          "UPDATE role_assignments SET status='revoked',revoked_at=timezone('UTC',now()),revocation_reason='manual' WHERE membership_id=$1 AND status='active'",
          [membership.id]
        )
      end)
    end
  end
end
