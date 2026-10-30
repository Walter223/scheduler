defmodule SchedulerApi.EmploymentHRConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.CompensationFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.Repo

  alias SchedulerApi.Employment.{
    HR,
    EmploymentRecord,
    ShopAssignment,
    ClassificationHistory,
    HrAuditEvent,
    WorkSchedules,
    WorkShift,
    WorkShiftAuditEvent
  }

  alias SchedulerApi.Organizations.{RoleAssignment, BusinessMembership}
  alias SchedulerApi.Accounts.WebSession

  setup do
    c = Sandbox.unboxed_run(Repo, &compensation_fixture/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from a in SchedulerApi.Employment.OffboardingAudit,
            where: a.business_id == ^c.business.id
        )

        Repo.delete_all(from a in HrAuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from a in WorkShiftAuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from w in WorkShift, where: w.business_id == ^c.business.id)
        Repo.delete_all(from a in ShopAssignment, where: a.business_id == ^c.business.id)
        Repo.delete_all(from h in ClassificationHistory, where: h.business_id == ^c.business.id)
        Repo.delete_all(from e in EmploymentRecord, where: e.business_id == ^c.business.id)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^c.business.id)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^c.business.id)
        Repo.delete_all(from s in WebSession, where: s.user_id == ^c.owner.id)
        Repo.delete!(c.shop)
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

  test "concurrent disjoint contact edits preserve both values and audits", c do
    results =
      compete(c, [
        fn -> HR.update_contact(c.credential, c.employment, %{phone: "555"}) end,
        fn ->
          HR.update_contact(c.credential, c.employment, %{home_address: "Private address"})
        end
      ])

    assert Enum.all?(results, &match?({:ok, _}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      e = Repo.reload!(c.employment)
      assert e.phone == "555" and e.home_address == "Private address"

      assert Repo.aggregate(
               from(a in HrAuditEvent, where: a.business_id == ^c.business.id),
               :count
             ) == 2
    end)
  end

  test "concurrent classifications serialize a complete history chain", c do
    results =
      compete(
        c,
        for(
          classification <- [:shop_manager, :business_manager],
          do: fn -> HR.change_classification(c.credential, c.employment, classification) end
        )
      )

    assert Enum.all?(results, &match?({:ok, _}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      [initial, first, last] =
        Repo.all(
          from h in ClassificationHistory, where: h.business_id == ^c.business.id, order_by: h.id
        )

      assert first.previous_classification == initial.classification
      assert last.previous_classification == first.classification
      assert Repo.reload!(c.employment).classification == last.classification

      assert Repo.aggregate(
               from(a in HrAuditEvent, where: a.business_id == ^c.business.id),
               :count
             ) == 2
    end)
  end

  test "duplicate shop creation gives one success and an audited normal denial", c do
    results =
      compete(
        c,
        for(
          _ <- 1..2,
          do: fn ->
            HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})
          end
        )
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :already_assigned}, &1)) == 1
  end

  test "ending an assignment cannot race past a newly created shift", c do
    a =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, a} =
          HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

        %ShopAssignment{id: a.id}
      end)

    start = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(86400)

    results =
      compete(c, [
        fn -> HR.end_shop_assignment(c.credential, a, Date.utc_today()) end,
        fn ->
          WorkSchedules.create_shift(c.credential, a, %{
            starts_at: start,
            ends_at: DateTime.add(start, 3600)
          })
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.any?(
             results,
             &(&1 in [{:error, :outstanding_work}, {:error, :ineligible_assignment}])
           )

    Sandbox.unboxed_run(Repo, fn ->
      assignment = Repo.get!(ShopAssignment, a.id)
      has_shift = Repo.exists?(from w in WorkShift, where: w.business_id == ^c.business.id)
      assert has_shift == (assignment.status == :active)
    end)
  end

  test "two offboarding requests create exactly one termination and historical audit", c do
    results =
      compete(
        c,
        for(_ <- 1..2, do: fn -> HR.terminate_employment(c.credential, c.employment) end)
      )

    assert Enum.count(results, &match?({:ok, %{already_terminated: false}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{already_terminated: true}}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.reload!(c.employment).status == :ended

      assert Repo.aggregate(
               from(a in SchedulerApi.Employment.OffboardingAudit,
                 where: a.business_id == ^c.business.id
               ),
               :count
             ) == 1
    end)
  end

  test "offboarding and shift creation serialize without active future work on ended employee",
       c do
    a =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, a} =
          HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

        %ShopAssignment{id: a.id}
      end)

    start = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(86400)

    results =
      compete(c, [
        fn -> HR.terminate_employment(c.credential, c.employment) end,
        fn ->
          WorkSchedules.create_shift(c.credential, a, %{
            starts_at: start,
            ends_at: DateTime.add(start, 3600)
          })
        end
      ])

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, :ineligible_assignment} -> true
             _ -> false
           end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.reload!(c.employment).status == :ended

      refute Repo.exists?(
               from w in WorkShift, where: w.business_id == ^c.business.id and w.status == :active
             )
    end)
  end
end
