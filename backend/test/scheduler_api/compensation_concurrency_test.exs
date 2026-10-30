defmodule SchedulerApi.CompensationConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.CompensationFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Repo, Employment}

  alias SchedulerApi.Employment.{
    Compensation,
    CompensationRate,
    CompensationAuditEvent,
    EmploymentRecord,
    ShopAssignment
  }

  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Accounts.{User, WebSession}

  @now ~U[2026-10-29 18:00:00Z]
  setup do
    c = Sandbox.unboxed_run(Repo, &compensation_fixture/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # Positively owned test rows only; production has no financial delete API.
        Repo.delete_all(from a in CompensationAuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from r in CompensationRate, where: r.employment_id == ^c.employment.id)
        Repo.delete_all(from a in ShopAssignment, where: a.employment_id == ^c.employment.id)
        Repo.delete!(c.employment)
        Repo.delete_all(from r in RoleAssignment, where: r.membership_id == ^c.membership.id)
        Repo.delete_all(from s in WebSession, where: s.user_id == ^c.owner.id)
        Repo.delete_all(from m in BusinessMembership, where: m.id == ^c.membership.id)
        Repo.delete_all(from s in Shop, where: s.id == ^c.shop.id)
        Repo.delete_all(from b in Business, where: b.id == ^c.business.id)
        Repo.delete_all(from u in User, where: u.id == ^c.owner.id)
      end)
    end)

    Map.put(c, :supervisor, start_supervised!(Task.Supervisor))
  end

  defp compete(supervisor, functions) do
    parent = self()

    tasks =
      for fun <- functions do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), pid})

            receive do
              :go -> fun.()
            after
              5000 -> raise "Missing concurrency barrier"
            end
          end)
        end)
      end

    assert_receive {:ready, a, pid_a}, 5000
    assert_receive {:ready, b, pid_b}, 5000
    refute pid_a == pid_b
    send(a, :go)
    send(b, :go)
    Enum.map(tasks, &Task.await(&1, 5000))
  end

  test "same-date competing pay changes serialize without losing history or audits", c do
    for date <- [~D[2026-10-29], ~D[2026-10-30], ~D[2026-10-31]] do
      functions =
        for amount <- ["25.00", "30.00"] do
          fn ->
            Compensation.set_rate(
              c.credential,
              c.employment,
              %{amount: amount, pay_basis: :hourly, effective_from: date},
              now: @now
            )
          end
        end

      results = compete(c.supervisor, functions)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :effective_date_conflict}, &1)) == 1
    end

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(CompensationRate, :count) == 3
      assert Repo.aggregate(CompensationAuditEvent, :count) == 6

      assert Repo.aggregate(from(r in CompensationRate, where: is_nil(r.effective_until)), :count) ==
               1
    end)
  end

  test "pay writes and shop assignment use consistent business-before-employment locking", c do
    parent = self()

    holder =
      Task.Supervisor.async_nolink(c.supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM businesses WHERE id=$1 FOR UPDATE", [c.business.id])
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:business_locked, self(), pid})

            receive do
              :proceed ->
                Compensation.set_rate(
                  c.credential,
                  c.employment,
                  %{amount: "25.00", pay_basis: :hourly, effective_from: ~D[2026-10-29]},
                  now: @now
                )
            after
              5000 -> raise "Missing lock-order barrier"
            end
          end)
        end)
      end)

    assert_receive {:business_locked, holder_process, holder_pid}, 5000

    assignment =
      Task.Supervisor.async_nolink(c.supervisor, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:assignment_connection, pid})
          Employment.assign_shop(c.employment, c.shop, %{starts_on: ~D[2026-01-01]})
        end)
      end)

    try do
      assert_receive {:assignment_connection, assignment_pid}, 5000

      wait_for_business_lock(
        assignment_pid,
        holder_pid,
        System.monotonic_time(:millisecond) + 4000
      )

      send(holder_process, :proceed)
      assert {:ok, {:ok, _}} = Task.await(holder, 5000)
      assert {:ok, _} = Task.await(assignment, 5000)
    after
      send(holder_process, :proceed)
    end
  end

  defp wait_for_business_lock(pid, holder, deadline) do
    blocked =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [pid])
        holder in blockers
      end)

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        wait_for_business_lock(pid, holder, deadline)

      true ->
        flunk("Assignment did not reach the business lock")
    end
  end

  test "direct independent writers still cannot insert overlapping pay periods", c do
    functions =
      for _ <- 1..2 do
        fn ->
          Repo.query(
            "INSERT INTO compensation_rates(business_id,employment_id,amount,pay_basis,currency,effective_from,inserted_at) VALUES($1,$2,25,'hourly','USD','2026-10-29',timezone('UTC',now()))",
            [c.business.id, c.employment.id],
            log: false
          )
        end
      end

    results = compete(c.supervisor, functions)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}}, &1)
           ) == 1
  end

  test "termination racing a pay change preserves every committed rate and audit", c do
    results =
      compete(c.supervisor, [
        fn ->
          Compensation.set_rate(
            c.credential,
            c.employment,
            %{amount: "25.00", pay_basis: :hourly, effective_from: ~D[2026-10-29]},
            now: @now
          )
        end,
        fn -> Employment.end_employment(c.employment, ~D[2026-10-30]) end
      ])

    assert Enum.any?(results, &match?({:ok, %EmploymentRecord{status: :ended}}, &1))

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, :employment_ended} -> true
             _ -> false
           end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(EmploymentRecord, c.employment.id).status == :ended
      assert Repo.aggregate(CompensationAuditEvent, :count) == 1
      audit = Repo.one!(CompensationAuditEvent)
      if audit.outcome == :applied, do: assert(Repo.get!(CompensationRate, audit.rate_id))
    end)
  end
end
