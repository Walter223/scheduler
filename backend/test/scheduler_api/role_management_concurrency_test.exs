defmodule SchedulerApi.RoleManagementConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Accounts.WebSession
  alias SchedulerApi.Authorization.{RoleManagement, AuditEvent}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}

  test "Manager delegation serializes with Owner grants and live permission revocation" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    for mode <- [:delegated_duplicate, :owner_protection, :manager_revocation] do
      {b, shop, records} =
        Sandbox.unboxed_run(Repo, fn ->
          b =
            Repo.insert!(%Business{
              name: "Delegation race",
              slug: "delegate-#{System.unique_integer([:positive])}"
            })

          shop =
            Repo.insert!(%SchedulerApi.Organizations.Shop{
              business_id: b.id,
              name: "Race",
              slug: "race",
              timezone: "America/Denver"
            })

          records =
            for role <- [:business_owner, :business_manager, :employee] do
              u = active_user_fixture()
              m = Repo.insert!(%BusinessMembership{user_id: u.id, business_id: b.id})

              r =
                Repo.insert!(%RoleAssignment{
                  business_id: b.id,
                  membership_id: m.id,
                  role: role,
                  shop_id: if(role == :employee, do: shop.id)
                })

              {:ok, _, token} = Accounts.create_session(u)
              {u, m, r, token}
            end

          {b, shop, records}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          ids = Enum.map(records, fn {u, _, _, _} -> u.id end)
          Repo.delete_all(from e in AuditEvent, where: e.business_id == ^b.id)
          Repo.delete_all(from s in WebSession, where: s.user_id in ^ids)
          Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^b.id)
          Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^b.id)
          Repo.delete!(shop)
          Repo.delete!(b)
          Enum.each(records, fn {u, _, _, _} -> Repo.delete!(u) end)
        end)
      end)

      [{_, _, _, owner_token}, {_, _, manager_role, manager_token}, {_, target, lower, _}] =
        records

      tasks =
        for who <- [:owner, :manager] do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:delegate_ready, self(), pid})

              receive do
                :go -> :ok
              after
                5000 -> raise "Missing race barrier"
              end

              case {mode, who} do
                {:delegated_duplicate, :owner} ->
                  RoleManagement.grant_role(owner_token, b, target, :shop_manager, shop)

                {:delegated_duplicate, :manager} ->
                  RoleManagement.grant_role(manager_token, b, target, :shop_manager, shop)

                {:owner_protection, :owner} ->
                  RoleManagement.grant_role(owner_token, b, target, :business_owner)

                {:owner_protection, :manager} ->
                  RoleManagement.revoke_role(manager_token, b, lower)

                {:manager_revocation, :owner} ->
                  RoleManagement.revoke_role(owner_token, b, manager_role)

                {:manager_revocation, :manager} ->
                  RoleManagement.grant_role(manager_token, b, target, :shop_manager, shop)
              end
            end)
          end)
        end

      assert_receive {:delegate_ready, a, pa}, 5000
      assert_receive {:delegate_ready, z, pz}, 5000
      refute pa == pz
      send(a, :go)
      send(z, :go)
      [owner_result, manager_result] = Enum.map(tasks, &Task.await(&1, 10000))

      if mode == :delegated_duplicate do
        assert Enum.count([owner_result, manager_result], &match?({:ok, _}, &1)) == 1
        assert {:error, :duplicate_grant} in [owner_result, manager_result]
      else
        assert {:ok, _} = owner_result
        assert match?({:ok, _}, manager_result) or manager_result == {:error, :forbidden}
      end

      Sandbox.unboxed_run(Repo, fn ->
        if mode != :delegated_duplicate do
          assert {:error, :forbidden} =
                   RoleManagement.grant_role(manager_token, b, target, :employee, shop)
        end

        assert Repo.aggregate(from(e in AuditEvent, where: e.business_id == ^b.id), :count) ==
                 if(mode == :delegated_duplicate, do: 2, else: 3)
      end)
    end
  end

  test "business lock prevents last-Owner loss and serializes duplicate grants" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    for mode <- [:role_role, :role_membership, :membership_membership, :duplicate] do
      {b, records} =
        Sandbox.unboxed_run(Repo, fn ->
          b =
            Repo.insert!(%Business{
              name: "Owner race",
              slug: "owner-race-#{System.unique_integer([:positive])}"
            })

          records =
            for _ <- 1..2 do
              u = active_user_fixture()
              m = Repo.insert!(%BusinessMembership{user_id: u.id, business_id: b.id})

              r =
                Repo.insert!(%RoleAssignment{
                  membership_id: m.id,
                  business_id: b.id,
                  role: :business_owner
                })

              {:ok, _, token} = Accounts.create_session(u)
              {u, m, r, token}
            end

          {b, records}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          ids = Enum.map(records, fn {u, _, _, _} -> u.id end)
          Repo.delete_all(from e in AuditEvent, where: e.business_id == ^b.id)
          Repo.delete_all(from s in WebSession, where: s.user_id in ^ids)
          Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^b.id)
          Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^b.id)
          Repo.delete!(b)
          Enum.each(records, fn {u, _, _, _} -> Repo.delete!(u) end)
        end)
      end)

      [{_, _, _, first_token}, {_, target, _, _}] = records

      tasks =
        for {{_, m, r, token}, index} <- Enum.with_index(records) do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), pid})

              receive do
                :go -> :ok
              after
                5000 -> raise "Missing barrier"
              end

              cond do
                mode == :duplicate ->
                  RoleManagement.grant_role(first_token, b, target, :business_manager)

                mode == :membership_membership or (mode == :role_membership and index == 1) ->
                  RoleManagement.revoke_membership(token, b, m)

                true ->
                  RoleManagement.revoke_role(token, b, r)
              end
            end)
          end)
        end

      assert_receive {:ready, a, pid_a}, 5000
      assert_receive {:ready, z, pid_z}, 5000
      refute pid_a == pid_z
      send(a, :go)
      send(z, :go)
      results = Enum.map(tasks, &Task.await(&1, 10000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      reason = if mode == :duplicate, do: :duplicate_grant, else: :last_owner
      assert Enum.count(results, &(&1 == {:error, reason})) == 1

      Sandbox.unboxed_run(Repo, fn ->
        remaining =
          Repo.aggregate(
            from(r in RoleAssignment,
              where: r.business_id == ^b.id and r.role == :business_owner and r.status == :active
            ),
            :count
          )

        assert remaining == if(mode == :duplicate, do: 2, else: 1)

        assert Repo.aggregate(
                 from(e in AuditEvent, where: e.business_id == ^b.id and e.outcome == :denied),
                 :count
               ) == 1
      end)
    end
  end
end
