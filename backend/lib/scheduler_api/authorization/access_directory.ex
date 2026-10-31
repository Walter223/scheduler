defmodule SchedulerApi.Authorization.AccessDirectory do
  @moduledoc "Bounded access-management projections; current complete grants scope SQL before paging."
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}

  def query(user, business_id, :memberships) do
    scopes = Authorization.staff_access_scopes_query(user, business_id)

    from m in BusinessMembership,
      where:
        m.business_id == ^business_id and
          m.id in subquery(from s in subquery(scopes), select: s.membership_id)
  end

  def query(user, business_id, :role_grants) do
    scopes = Authorization.staff_access_scopes_query(user, business_id)

    from r in RoleAssignment,
      join: s in subquery(scopes),
      on: s.membership_id == r.membership_id,
      where:
        r.business_id == ^business_id and
          (s.owner or r.role in [:employee, :shop_manager]),
      distinct: true
  end

  def list(user, business_id, kind, params) do
    with :ok <- Authorization.authorize(user, :staff_access_read, %Business{id: business_id}),
         {:ok, limit} <- limit(Map.get(params, "limit", "50")),
         {:ok, status} <- status(Map.get(params, "status", "active")),
         binding = [business_id, user.id, Atom.to_string(kind), status],
         {:ok, after_id} <- cursor(params["cursor"], binding) do
      rows =
        query(user, business_id, kind)
        |> where([r], r.status == ^status and r.id > ^after_id)
        |> order_by([r], asc: r.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      more = length(rows) > limit
      items = Enum.take(rows, limit)

      next =
        if more,
          do: Base.url_encode64(Jason.encode!(binding ++ [List.last(items).id]), padding: false)

      {:ok, %{items: Enum.map(items, &project/1), has_more: more, next_cursor: next}}
    end
  end

  def project(%BusinessMembership{} = m),
    do: Map.take(m, [:id, :business_id, :user_id, :status, :inserted_at, :revoked_at])

  def project(%RoleAssignment{} = r),
    do:
      Map.take(r, [
        :id,
        :business_id,
        :membership_id,
        :role,
        :shop_id,
        :status,
        :inserted_at,
        :revoked_at
      ])

  defp limit(v) when is_binary(v) and byte_size(v) in 1..3 do
    case Integer.parse(v) do
      {n, ""} when n in 1..100 -> {:ok, n}
      _ -> {:error, :invalid_input}
    end
  end

  defp limit(_), do: {:error, :invalid_input}
  defp status(v) when v in ["active", "revoked"], do: {:ok, v}
  defp status(_), do: {:error, :invalid_input}
  defp cursor(nil, _), do: {:ok, 0}

  defp cursor(v, [b, u, k, s]) when is_binary(v) and byte_size(v) in 1..512 do
    with {:ok, json} <- Base.url_decode64(v, padding: false),
         {:ok, [^b, ^u, ^k, ^s, id]} <- Jason.decode(json),
         true <- is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
         do: {:ok, id},
         else: (_ -> {:error, :invalid_input})
  end

  defp cursor(_, _), do: {:error, :invalid_input}
end
