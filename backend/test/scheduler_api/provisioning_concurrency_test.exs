defmodule SchedulerApi.ProvisioningConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Repo, Provisioning}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Authorization.AuditEvent
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Provisioning.{Credential, Intent}

  @now ~U[2026-11-06 12:00:00Z]

  defp fixture(count) do
    {users, credentials, ids} =
      Sandbox.unboxed_run(Repo, fn ->
        slug = "provision-race-#{System.unique_integer([:positive])}"

        attrs = %{
          business: %{name: "Provision race", slug: slug},
          shop: %{name: "Initial", slug: "initial", timezone: "America/Denver"}
        }

        users = for _ <- 1..count, do: active_user_fixture()

        credentials =
          Enum.map(users, fn u ->
            {:ok, credential} =
              Provisioning.authorize_operator(u.keycloak_issuer, u.keycloak_subject, attrs,
                now: @now
              )

            credential
          end)

        ids =
          Enum.map(credentials, fn c ->
            {:ok, hash} = Credential.digest(c)
            Repo.get_by!(Intent, credential_hash: hash).id
          end)

        {users, credentials, ids}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        businesses =
          Repo.all(
            from i in Intent,
              where: i.id in ^ids and not is_nil(i.business_id),
              select: i.business_id
          )

        Repo.delete_all(from i in Intent, where: i.id in ^ids)
        Repo.delete_all(from e in AuditEvent, where: e.business_id in ^businesses)
        Repo.delete_all(from r in RoleAssignment, where: r.business_id in ^businesses)
        Repo.delete_all(from m in BusinessMembership, where: m.business_id in ^businesses)
        Repo.delete_all(from s in Shop, where: s.business_id in ^businesses)
        Repo.delete_all(from b in Business, where: b.id in ^businesses)
        Repo.delete_all(from u in User, where: u.id in ^Enum.map(users, & &1.id))
      end)
    end)

    credentials
  end

  defp race(credentials) do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for credential <- credentials do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), pid})

            receive do
              :go -> :ok
            after
              5000 -> raise "Missing provisioning barrier"
            end

            Provisioning.provision(credential, now: @now)
          end)
        end)
      end

    assert_receive {:ready, a, pid_a}, 5000
    assert_receive {:ready, b, pid_b}, 5000
    refute pid_a == pid_b
    send(a, :go)
    send(b, :go)
    Enum.map(tasks, &Task.await(&1, 10000))
  end

  test "concurrent identical capability returns exactly the same committed result" do
    [credential] = fixture(1)
    [a, b] = race([credential, credential])
    assert {:ok, result} = a
    assert b == a

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(r in RoleAssignment, where: r.business_id == ^result.business_id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.business_id == ^result.business_id),
               :count
             ) == 1

      assert Repo.aggregate(from(s in Shop, where: s.business_id == ^result.business_id), :count) ==
               1
    end)
  end

  test "independent owners racing on one slug cannot claim or share the winning tenant" do
    credentials = fixture(2)
    results = race(credentials)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :slug_unavailable})) == 1

    Sandbox.unboxed_run(Repo, fn ->
      for {credential, result} <- Enum.zip(credentials, results) do
        {:ok, hash} = Credential.digest(credential)
        intent = Repo.get_by!(Intent, credential_hash: hash)

        case result do
          {:ok, r} ->
            assert intent.business_id == r.business_id
            assert Repo.get!(BusinessMembership, r.membership_id).user_id == intent.owner_id

          {:error, :slug_unavailable} ->
            assert is_nil(intent.completed_at) and is_nil(intent.business_id)

            refute Repo.exists?(
                     from m in BusinessMembership, where: m.user_id == ^intent.owner_id
                   )
        end
      end
    end)
  end
end
