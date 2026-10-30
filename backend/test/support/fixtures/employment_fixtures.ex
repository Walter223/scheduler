defmodule SchedulerApi.EmploymentFixtures do
  alias SchedulerApi.{Employment, Repo}
  alias SchedulerApi.Organizations.Business

  def employment_fixture(attrs \\ %{}, opts \\ []) do
    business =
      Keyword.get_lazy(opts, :business, fn ->
        Repo.insert!(%Business{
          name: "Employment test",
          slug: "employment-#{System.unique_integer([:positive])}"
        })
      end)

    {:ok, record} =
      Employment.create_employment(
        business,
        Map.merge(
          %{
            first_name: "Taylor",
            last_name: "Worker",
            classification: :detailer,
            starts_on: ~D[2026-01-01]
          },
          attrs
        ),
        Keyword.take(opts, [:user])
      )

    record
  end
end
