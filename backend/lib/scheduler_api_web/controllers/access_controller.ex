defmodule SchedulerApiWeb.AccessController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApiWeb.BrowserSession

  for action <- [
        :memberships,
        :role_grants,
        :grant,
        :revoke,
        :revoke_membership,
        :reactivate_membership
      ] do
    def unquote(action)(conn, _), do: handle(conn, unquote(action))
  end

  defp handle(conn, action) do
    case SchedulerApi.Authorization.AccessHTTP.run(
           action,
           conn.assigns.magnum_session,
           %SessionCredential{value: conn.req_cookies[BrowserSession.session_name()]},
           conn.path_params,
           if(action in [:memberships, :role_grants], do: %{}, else: conn.body_params),
           conn.query_params
         ) do
      {:ok, value} ->
        conn |> put_status(if(action == :grant, do: 201, else: 200)) |> json(%{data: value})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :persistence_failed} ->
        conn |> put_status(503) |> json(%{error: "operation_unavailable"})

      {:error, reason} when reason in [:last_owner, :duplicate_grant, :ineligible_target] ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(reason)})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
