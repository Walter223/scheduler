defmodule SchedulerApi.Employment.CompensationHTTP do
  @moduledoc "Strict HTTP adapter; all compensation writes and read policy remain domain-owned."
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Employment.{Compensation, EmploymentRecord}
  alias SchedulerApi.Organizations.Business

  def run(action, session, credential, path, body, params) do
    with {:ok, biz} <- id(path["business_id"]), :ok <- fields(action, body, params) do
      if action == :own do
        with {:ok, rate} <- Compensation.get_own_current_rate(session.user, %Business{id: biz}) do
          {:ok, normalize(rate)}
        end
      else
        with {:ok, employee} <- id(path["employee_id"]), {:ok, period} <- id(path["period_id"]) do
          permission = if action == :create, do: :compensation_write, else: :compensation_read

          first =
            Authorization.authorized_compensation_employment_ids_query(session.user, permission)

          own_shop =
            Authorization.authorized_compensation_employment_ids_query(
              session.user,
              :assigned_employee_compensation_read
            )

          query =
            from e in EmploymentRecord,
              where: e.id == ^period and e.employee_id == ^employee and e.business_id == ^biz

          query =
            if action == :current,
              do:
                where(
                  query,
                  [e],
                  e.id in subquery(from p in subquery(first), select: p.id) or
                    e.id in subquery(from p in subquery(own_shop), select: p.id)
                ),
              else: where(query, [e], e.id in subquery(from p in subquery(first), select: p.id))

          case Repo.one(query) do
            nil -> {:error, :forbidden}
            e -> invoke(action, session.user, credential, e, body, query_params(action, params))
          end
        end
      end
    end
  end

  defp invoke(:create, _, c, e, b, _), do: map_rate(Compensation.set_rate(c, e, b))
  defp invoke(:current, u, _, e, _, _), do: map_rate(Compensation.get_current_rate(u, e))

  defp invoke(:history, u, _, e, _, opts) do
    with {:ok, page} <- Compensation.page_rate_history(u, e, opts) do
      {:ok, %{page | rates: Enum.map(page.rates, &normalize/1)}}
    end
  end

  defp map_rate({:ok, rate}), do: {:ok, normalize(rate)}
  defp map_rate(error), do: error
  defp normalize(nil), do: nil

  defp normalize(rate) do
    employee =
      Repo.one!(
        from e in EmploymentRecord,
          where: e.id == ^rate.employment_id and e.business_id == ^rate.business_id,
          select: e.employee_id
      )

    rate
    |> Map.drop([:id, :employment_id])
    |> Map.merge(%{rate_id: rate.id, period_id: rate.employment_id, employee_id: employee})
  end

  defp fields(action, body, q) do
    keys =
      if action == :create,
        do: ~w(amount pay_basis currency effective_from effective_until),
        else: []

    queries = if action == :history, do: ~w(limit cursor), else: []

    if is_map(body) and Enum.all?(Map.keys(body), &(&1 in keys)) and
         Enum.all?(Map.keys(q), &(&1 in queries)), do: :ok, else: {:error, :invalid_input}
  end

  defp query_params(:history, q) do
    limit =
      case id(Map.get(q, "limit", "50")) do
        {:ok, n} -> n
        _ -> :invalid
      end

    [limit: limit, cursor: Map.get(q, "cursor")]
  end

  defp query_params(_, _), do: []

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> {:error, :invalid_input}
    end
  end

  defp id(_), do: {:error, :invalid_input}
end
