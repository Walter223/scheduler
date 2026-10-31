defmodule SchedulerApiWeb.CompensationController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApiWeb.BrowserSession

  for action <- [:current, :history, :own, :create] do
    def unquote(action)(conn, _), do: handle(conn, unquote(action))
  end

  defp handle(conn, action) do
    result =
      SchedulerApi.Employment.CompensationHTTP.run(
        action,
        conn.assigns.magnum_session,
        %SessionCredential{value: conn.req_cookies[BrowserSession.session_name()]},
        conn.path_params,
        if(action == :create, do: conn.body_params, else: %{}),
        conn.query_params
      )

    case result do
      {:ok, value} ->
        conn |> put_status(if(action == :create, do: 201, else: 200)) |> json(%{data: value})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :persistence_failed} ->
        conn |> put_status(503) |> json(%{error: "operation_unavailable"})

      {:error, e} when e in [:effective_date_conflict, :employment_ended] ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(e)})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
