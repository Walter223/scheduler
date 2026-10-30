defmodule SchedulerApi.WorkShiftConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.WorkShiftFixtures
  import SchedulerApi.ShopsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Employment, Repo}
  alias SchedulerApi.Employment.{WorkSchedules, WorkShift, WorkShiftAuditEvent, ShopAssignment}
  alias SchedulerApi.Organizations.RoleAssignment
  alias SchedulerApi.Accounts.WebSession
  @now ~U[2026-10-30 12:00:00Z]
  @attrs %{starts_at: ~U[2026-11-02 16:00:00Z], ends_at: ~U[2026-11-02 19:00:00Z]}

  setup do
    c =
      Sandbox.unboxed_run(Repo, fn ->
        c = work_shift_fixture()
        other = shop_fixture(%{business_id: c.business.id})
        {:ok, a} = Employment.assign_shop(c.employment, other, %{starts_on: ~D[2026-01-01]})
        Map.merge(c, %{other_shop: other, other_assignment: a})
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in WorkShiftAuditEvent, where: a.business_id == ^c.business.id)
        # Replacement IDs are newer: delete children before parents, preserving FKs.
        for shift <-
              Repo.all(
                from w in WorkShift,
                  where: w.business_id == ^c.business.id,
                  order_by: [desc: w.id]
              ),
            do: Repo.delete!(shift)

        Repo.delete_all(from a in ShopAssignment, where: a.employment_id == ^c.employment.id)
        Repo.delete!(c.employment)
        Repo.delete_all(from r in RoleAssignment, where: r.membership_id == ^c.membership.id)
        Repo.delete_all(from s in WebSession, where: s.user_id == ^c.owner.id)
        Repo.delete!(c.membership)
        Repo.delete!(c.shop)
        Repo.delete!(c.other_shop)
        Repo.delete!(c.business)
        Repo.delete!(c.owner)
      end)
    end)

    Map.put(c, :supervisor, start_supervised!(Task.Supervisor))
  end

  defp compete(c, functions) do
    parent = self()

    tasks =
      for fun <- functions do
        Task.Supervisor.async_nolink(c.supervisor, fn ->
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

  test "independent overlapping creation across shops gives one success and a normal overlap denial",
       c do
    for offset <- [0, 86400, 172_800] do
      attrs = %{
        starts_at: DateTime.add(@attrs.starts_at, offset),
        ends_at: DateTime.add(@attrs.ends_at, offset)
      }

      functions =
        for assignment <- [c.assignment, c.other_assignment] do
          fn -> WorkSchedules.create_shift(c.credential, assignment, attrs, now: @now) end
        end

      results = compete(c, functions)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :overlap}, &1)) == 1
    end

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(WorkShift, :count) == 3
      assert Repo.aggregate(WorkShiftAuditEvent, :count) == 6
    end)
  end

  test "direct SQL writers remain protected against cross-shop overlap", c do
    functions =
      for a <- [c.assignment, c.other_assignment] do
        fn ->
          Repo.query(
            "INSERT INTO work_shifts(assignment_id,employment_id,business_id,shop_id,starts_at,ends_at,timezone,inserted_at) VALUES($1,$2,$3,$4,$5,$6,'America/Denver',$7)",
            [
              a.id,
              c.employment.id,
              c.business.id,
              a.shop_id,
              DateTime.to_naive(@attrs.starts_at),
              DateTime.to_naive(@attrs.ends_at),
              DateTime.to_naive(@now)
            ],
            log: false
          )
        end
      end

    results = compete(c, functions)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}}, &1)
           ) == 1
  end

  test "competing replacements preserve one original, one replacement and both audit outcomes",
       c do
    original =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, s} = WorkSchedules.create_shift(c.credential, c.assignment, @attrs, now: @now)
        s
      end)

    functions =
      for offset <- [3600, 7200] do
        fn ->
          WorkSchedules.reschedule_shift(
            c.credential,
            %WorkShift{id: original.id},
            %{
              starts_at: DateTime.add(@attrs.starts_at, offset),
              ends_at: DateTime.add(@attrs.ends_at, offset)
            },
            now: @now
          )
        end
      end

    results = compete(c, functions)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_active}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(WorkShift, original.id).status == :superseded
      assert Repo.aggregate(WorkShift, :count) == 2
      assert Repo.aggregate(from(w in WorkShift, where: w.status == :active), :count) == 1
      assert Repo.aggregate(WorkShiftAuditEvent, :count) == 3
    end)
  end

  test "termination and creation serialize without deleting any committed history", c do
    results =
      compete(c, [
        fn -> WorkSchedules.create_shift(c.credential, c.assignment, @attrs, now: @now) end,
        fn -> Employment.end_employment(c.employment, ~D[2026-10-31]) end
      ])

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, :ineligible_assignment} -> true
             _ -> false
           end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.reload!(c.employment).status == :ended
      assert Repo.reload!(c.assignment).status == :ended
      assert Repo.aggregate(WorkShiftAuditEvent, :count) == 1
      audit = Repo.one!(WorkShiftAuditEvent)
      if audit.outcome == :applied, do: assert(Repo.get!(WorkShift, audit.shift_id))
    end)
  end
end
