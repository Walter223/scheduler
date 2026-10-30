defmodule SchedulerApi.OwnerTerminationConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.CompensationFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Accounts, Repo}

  alias SchedulerApi.Employment.{
    HR,
    EmploymentRecord,
    ClassificationHistory,
    HrAuditEvent,
    OffboardingAudit
  }

  alias SchedulerApi.Authorization.{RoleManagement, AuditEvent}
  alias SchedulerApi.Organizations.{RoleAssignment, BusinessMembership}
  alias SchedulerApi.Accounts.WebSession

  setup do
    c =
      Sandbox.unboxed_run(Repo, fn ->
        c = compensation_fixture()
        manager = active_user_fixture()
        grant_fixture(manager, c.shop, :business_manager)
        {:ok, _, token} = Accounts.create_session(manager)
        worker = active_user_fixture()
        {member, _} = grant_fixture(worker, c.shop, :employee)
        e = employment_fixture(%{}, business: c.business, user: worker)
        Map.merge(c, %{manager: manager, token: token, worker: worker, member: member, target: e})
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in OffboardingAudit, where: a.business_id == ^c.business.id)
        Repo.delete_all(from a in HrAuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from a in AuditEvent, where: a.business_id == ^c.business.id)
        Repo.delete_all(from h in ClassificationHistory, where: h.business_id == ^c.business.id)
        Repo.delete_all(from e in EmploymentRecord, where: e.business_id == ^c.business.id)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id == ^c.business.id)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id == ^c.business.id)

        Repo.delete_all(
          from s in WebSession, where: s.user_id in ^[c.owner.id, c.manager.id, c.worker.id]
        )

        Repo.delete!(c.shop)
        Repo.delete!(c.business)
        for user <- [c.owner, c.manager, c.worker], do: Repo.delete!(user)
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
              5000 -> raise "Missing barrier"
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

  test "Owner classification downgrade racing HR termination cannot erase protection", c do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} = HR.change_classification(c.credential, c.target, :business_owner)
    end)

    [change, termination] =
      compete(c, [
        fn -> HR.change_classification(c.credential, c.target, :detailer) end,
        fn -> HR.terminate_employment(c.token, c.target) end
      ])

    assert {:ok, _} = change
    assert termination == {:error, :forbidden}
    Sandbox.unboxed_run(Repo, fn -> assert Repo.reload!(c.target).status == :active end)
  end

  test "Owner grant revocation racing HR termination retains historical ownership protection",
       c do
    role =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, r} = RoleManagement.grant_role(c.credential, c.business, c.member, :business_owner)
        r
      end)

    [revocation, termination] =
      compete(c, [
        fn -> RoleManagement.revoke_role(c.credential, c.business, role) end,
        fn -> HR.terminate_employment(c.token, c.target) end
      ])

    assert {:ok, _} = revocation
    assert termination == {:error, :forbidden}
    Sandbox.unboxed_run(Repo, fn -> assert Repo.reload!(c.target).status == :active end)
  end

  test "Owner grant creation and termination serialize without an Owner grant on terminated employment",
       c do
    [grant, termination] =
      compete(c, [
        fn -> RoleManagement.grant_role(c.credential, c.business, c.member, :business_owner) end,
        fn -> HR.terminate_employment(c.token, c.target) end
      ])

    case grant do
      {:ok, _} -> assert termination == {:error, :forbidden}
      {:error, :ineligible_target} -> assert {:ok, _} = termination
      other -> flunk("Unexpected grant result: #{inspect(other)}")
    end

    Sandbox.unboxed_run(Repo, fn ->
      if Repo.reload!(c.target).status == :ended do
        refute Repo.exists?(
                 from r in RoleAssignment,
                   where: r.membership_id == ^c.member.id and r.status == :active
               )
      end
    end)
  end
end
