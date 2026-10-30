defmodule SchedulerApi.OwnerBootstrapConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.Repo
  alias SchedulerApi.Authorization.{OwnerBootstrap, AuditEvent}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}

  test "simultaneous first-Owner attempts yield exactly one applied event/grant" do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    for _ <- 1..3 do
      {b, users} =
        Sandbox.unboxed_run(Repo, fn ->
          {Repo.insert!(%Business{
             name: "Bootstrap race",
             slug: "bootstrap-race-#{System.unique_integer([:positive])}"
           }), [active_user_fixture(), active_user_fixture()]}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in AuditEvent, where: e.business_id == ^b.id)
          Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^b.id)
          Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^b.id)
          Repo.delete!(b)
          Enum.each(users, &Repo.delete!/1)
        end)
      end)

      tasks =
        for u <- users do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), pid})

              receive do
                :go -> :ok
              after
                5000 -> raise "Missing barrier"
              end

              OwnerBootstrap.run(b.id, u.keycloak_issuer, u.keycloak_subject, apply: true)
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
      assert Enum.count(results, &(&1 == {:error, :existing_owner_history})) == 1

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(r in RoleAssignment, where: r.business_id == ^b.id), :count) ==
                 1

        assert Repo.aggregate(
                 from(e in AuditEvent, where: e.business_id == ^b.id and e.outcome == :applied),
                 :count
               ) == 1

        assert Repo.aggregate(
                 from(e in AuditEvent, where: e.business_id == ^b.id and e.outcome == :denied),
                 :count
               ) == 1
      end)
    end
  end
end
