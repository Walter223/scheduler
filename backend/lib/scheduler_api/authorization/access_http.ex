defmodule SchedulerApi.Authorization.AccessHTTP do
  @moduledoc "Strict HTTP adaptation only; RoleManagement owns all audited mutations."
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Authorization.{AccessDirectory, RoleManagement}
  alias SchedulerApi.Organizations.{Business, RoleAssignment, Shop}

  def run(action, session, credential, path, body, params) do
    with {:ok, bid} <- id(path["business_id"]),
         :ok <- fields(action, body, params),
         :ok <- Authorization.authorize(session.user, :staff_access_read, %Business{id: bid}) do
      if action in [:memberships, :role_grants] do
        AccessDirectory.list(session.user, bid, action, params)
      else
        with {:ok, target_id} <-
               id(
                 if(action == :grant,
                   do: body["membership_id"],
                   else: path[if(action == :revoke, do: "grant_id", else: "membership_id")]
                 )
               ),
             kind = if(action == :revoke, do: :role_grants, else: :memberships),
             target when not is_nil(target) <-
               Repo.one(
                 from r in AccessDirectory.query(session.user, bid, kind),
                   where: r.id == ^target_id
               ) do
          invoke(action, credential, %Business{id: bid}, target, body)
          |> result()
        else
          nil -> {:error, :forbidden}
          error -> error
        end
      end
    end
  end

  defp invoke(:grant, c, b, m, body) do
    with {:ok, role} <- role(body["role"]), {:ok, shop} <- shop(body["shop_id"], b.id) do
      RoleManagement.grant_role(c, b, m, role, shop)
    end
  end

  defp invoke(:revoke, c, b, r, _), do: RoleManagement.revoke_role(c, b, r)
  defp invoke(:revoke_membership, c, b, m, _), do: RoleManagement.revoke_membership(c, b, m)

  defp invoke(:reactivate_membership, c, b, m, _),
    do: RoleManagement.reactivate_membership(c, b, m)

  defp result({:ok, value}), do: {:ok, AccessDirectory.project(value)}
  defp result({:error, :invalid_target}), do: {:error, :forbidden}
  defp result(error), do: error

  defp fields(action, body, params) do
    keys = if action == :grant, do: ~w(membership_id role shop_id), else: []
    queries = if action in [:memberships, :role_grants], do: ~w(limit cursor status), else: []

    if is_map(body) and Enum.all?(Map.keys(body), &(&1 in keys)) and
         Enum.all?(Map.keys(params), &(&1 in queries)), do: :ok, else: {:error, :invalid_input}
  end

  defp role(value) do
    case Enum.find(RoleAssignment.roles(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_input}
      role -> {:ok, role}
    end
  end

  defp shop(nil, _), do: {:ok, nil}

  defp shop(value, bid) do
    with {:ok, sid} <- id(value) do
      case Repo.get_by(Shop, id: sid, business_id: bid, status: :active) do
        nil -> {:error, :invalid_scope}
        shop -> {:ok, shop}
      end
    end
  end

  defp id(v) when is_integer(v) and v > 0 and v <= 9_223_372_036_854_775_807, do: {:ok, v}

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} -> id(n)
      _ -> {:error, :invalid_input}
    end
  end

  defp id(_), do: {:error, :invalid_input}
end
