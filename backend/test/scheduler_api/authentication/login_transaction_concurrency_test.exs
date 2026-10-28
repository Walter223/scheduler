defmodule SchedulerApi.Authentication.LoginTransactionConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.OidcFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Authentication, Repo}
  alias SchedulerApi.Authentication.{Credential, LoginTransaction}

  test "independent connections consume once, clear secrets, and never deadlock" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    now = ~U[2026-10-27 18:00:00Z]

    for _ <- 1..10 do
      {:ok, attempt} =
        Sandbox.unboxed_run(Repo, fn ->
          Authentication.create_login_transaction(config(), now: now)
        end)

      id = attempt.transaction.id

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from t in LoginTransaction, where: t.id == ^id)
        end)
      end)

      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn ->
              # Each contender holds its own checked-out connection before release.
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), backend_pid})

              receive do
                :go ->
                  Authentication.consume_login_transaction(
                    Credential.reveal(attempt.state),
                    Credential.reveal(attempt.browser_binding),
                    now: now
                  )
              after
                5_000 -> raise "missing concurrency release"
              end
            end)
          end)
        end

      assert_receive {:ready, first, first_backend}, 5_000
      assert_receive {:ready, second, second_backend}, 5_000
      refute first_backend == second_backend
      send(first, :go)
      send(second, :go)
      results = Enum.map(tasks, &Task.await(&1, 5_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_login_transaction}, &1)) == 1

      Sandbox.unboxed_run(Repo, fn ->
        t = Repo.get!(LoginTransaction, id)
        assert t.consumed_at == now
        assert is_nil(t.nonce) and is_nil(t.pkce_verifier)
      end)
    end
  end
end
