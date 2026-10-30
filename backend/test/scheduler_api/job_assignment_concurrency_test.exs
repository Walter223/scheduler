defmodule SchedulerApi.JobAssignmentConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.JobAssignmentFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Employment, Repo}

  alias SchedulerApi.Appointments.{
    JobAssignments,
    JobAssignment,
    JobAssignmentAuditEvent,
    Appointment
  }

  alias SchedulerApi.Employment.{
    EmploymentRecord,
    ShopAssignment,
    WorkShift,
    WorkShiftAuditEvent,
    WorkSchedules
  }

  alias SchedulerApi.Organizations.{RoleAssignment, BusinessMembership, Shop}
  alias SchedulerApi.Accounts.WebSession
  alias SchedulerApi.Catalog.{Service, VehicleSize, ServicePrice}

  setup do
    c =
      Sandbox.unboxed_run(Repo, fn ->
        c = job_fixture()
        Map.put(c, :next, second_detailer(c))
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # Positive ownership by this unique business, children before parents.
        Repo.delete_all(from j in JobAssignmentAuditEvent, where: j.business_id == ^c.business.id)
        Repo.delete_all(from j in JobAssignment, where: j.business_id == ^c.business.id)
        Repo.delete_all(from a in WorkShiftAuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from w in WorkShift, where: w.business_id == ^c.business.id)
        Repo.delete_all(from a in ShopAssignment, where: a.business_id == ^c.business.id)
        Repo.delete_all(from e in EmploymentRecord, where: e.business_id == ^c.business.id)
        Repo.delete_all(from a in Appointment, where: a.business_id == ^c.business.id)
        Repo.delete_all(from p in ServicePrice, where: p.business_id == ^c.business.id)
        Repo.delete_all(from s in Service, where: s.business_id == ^c.business.id)
        Repo.delete_all(from v in VehicleSize, where: v.business_id == ^c.business.id)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^c.business.id)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^c.business.id)
        Repo.delete_all(from s in WebSession, where: s.user_id in ^[c.owner.id, c.detailer.id])
        Repo.delete_all(from s in Shop, where: s.business_id == ^c.business.id)
        Repo.delete!(c.business)
        Repo.delete!(c.owner)
        Repo.delete!(c.detailer)
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

  test "three independent-connection races give one assignee, normal duplicate denial and no deadlock",
       c do
    for _ <- 1..3 do
      functions =
        for a <- [c.assignment, c.next.assignment],
            do: fn -> JobAssignments.assign(c.credential, c.booking, a) end

      results = compete(c, functions)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :already_assigned}, &1)) == 1

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(
                 from(j in JobAssignment,
                   where: j.business_id == ^c.business.id and j.status == :active
                 ),
                 :count
               ) == 1

        assert {:ok, _} = JobAssignments.unassign(c.credential, c.booking)
      end)
    end

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(j in JobAssignment, where: j.business_id == ^c.business.id),
               :count
             ) == 3

      assert Repo.aggregate(
               from(a in JobAssignmentAuditEvent, where: a.business_id == ^c.business.id),
               :count
             ) == 9
    end)
  end

  test "termination competes safely with assignment, retaining every committed job", c do
    results =
      compete(c, [
        fn -> JobAssignments.assign(c.credential, c.booking, c.assignment) end,
        fn -> Employment.end_employment(c.employment, Date.utc_today()) end
      ])

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, :ineligible_detailer} -> true
             _ -> false
           end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.reload!(c.employment).status == :ended
      assert Repo.get!(Appointment, c.booking.id)
      assert Repo.get!(WorkShift, c.shift.id)

      assert Repo.aggregate(
               from(a in JobAssignmentAuditEvent, where: a.business_id == ^c.business.id),
               :count
             ) == 1
    end)
  end

  test "shift cancellation and job assignment cannot leave an active job without a covering shift",
       c do
    results =
      compete(c, [
        fn -> JobAssignments.assign(c.credential, c.booking, c.assignment) end,
        fn -> WorkSchedules.cancel_shift(c.credential, %WorkShift{id: c.shift.id}) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.any?(
             results,
             &(&1 in [{:error, :assigned_jobs}, {:error, :missing_covering_shift}])
           )

    Sandbox.unboxed_run(Repo, fn ->
      shift = Repo.get!(WorkShift, c.shift.id)

      active =
        Repo.exists?(
          from j in JobAssignment, where: j.business_id == ^c.business.id and j.status == :active
        )

      assert active == (shift.status == :active)
    end)
  end

  test "competing unassignments preserve one closure and a clean not-assigned denial", c do
    original =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, j} = JobAssignments.assign(c.credential, c.booking, c.assignment)
        j
      end)

    results =
      compete(c, for(_ <- 1..2, do: fn -> JobAssignments.unassign(c.credential, c.booking) end))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_assigned}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(JobAssignment, original.id).status == :unassigned

      assert Repo.aggregate(
               from(a in JobAssignmentAuditEvent, where: a.business_id == ^c.business.id),
               :count
             ) == 3
    end)
  end
end
