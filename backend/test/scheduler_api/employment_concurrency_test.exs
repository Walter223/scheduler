defmodule SchedulerApi.EmploymentConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.ShopsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias SchedulerApi.{Employment, Repo}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment}
  alias SchedulerApi.Organizations.{Business, Shop}

  setup do
    {record, shop} =
      Sandbox.unboxed_run(Repo, fn ->
        record = employment_fixture()
        {record, shop_fixture(%{business_id: record.business_id})}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from a in ShopAssignment, where: a.employment_id == ^record.id)

        Repo.delete_all(
          from h in SchedulerApi.Employment.ClassificationHistory,
            where: h.employment_id == ^record.id
        )

        Repo.delete_all(from e in EmploymentRecord, where: e.id == ^record.id)
        Repo.delete_all(from s in Shop, where: s.id == ^shop.id)
        Repo.delete_all(from b in Business, where: b.id == ^record.business_id)
      end)
    end)

    %{record: record, shop: shop, supervisor: start_supervised!(Task.Supervisor)}
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

    assert_receive {:ready, first, a}, 5000
    assert_receive {:ready, second, b}, 5000
    refute a == b
    send(first, :go)
    send(second, :go)
    Enum.map(tasks, &Task.await(&1, 5000))
  end

  test "independent concurrent duplicate assignments return one success and one changeset", c do
    for _ <- 1..3 do
      functions =
        for _ <- 1..2 do
          fn -> Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]}) end
        end

      results = compete(c.supervisor, functions)

      assert [{:ok, assignment}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, changeset}] =
               Enum.filter(results, &match?({:error, %Ecto.Changeset{}}, &1))

      assert Keyword.has_key?(changeset.errors, :shop_id)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, _} = Employment.end_shop_assignment(assignment, ~D[2026-01-02])
      end)
    end
  end

  test "assignment creation cannot race past employment termination", c do
    results =
      compete(c.supervisor, [
        fn -> Employment.assign_shop(c.record, c.shop, %{starts_on: ~D[2026-01-01]}) end,
        fn -> Employment.end_employment(c.record, ~D[2026-02-01]) end
      ])

    assert Enum.any?(results, &match?({:ok, %EmploymentRecord{status: :ended}}, &1))

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, :employment_ended} -> true
             _ -> false
           end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(EmploymentRecord, c.record.id).status == :ended

      refute Repo.exists?(
               from a in ShopAssignment,
                 where: a.employment_id == ^c.record.id and a.status == :active
             )
    end)
  end
end
