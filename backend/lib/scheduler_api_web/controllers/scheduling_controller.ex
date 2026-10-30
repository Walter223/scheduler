defmodule SchedulerApiWeb.SchedulingController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApiWeb.BrowserSession

  for action <- [
        :appointments,
        :team,
        :shifts,
        :employee_shifts,
        :own_jobs,
        :own_shifts,
        :create_shift,
        :cancel_shift,
        :reschedule_shift,
        :add,
        :remove,
        :lead,
        :clear_lead
      ] do
    def unquote(action)(conn, _), do: handle(conn, unquote(action))
  end

  defp handle(conn, action) do
    write = conn.method != "GET"

    result =
      SchedulerApi.Employment.SchedulingHTTP.run(
        action,
        conn.assigns.magnum_session,
        %SessionCredential{value: conn.req_cookies[BrowserSession.session_name()]},
        conn.path_params,
        if(write, do: conn.body_params, else: %{}),
        conn.query_params
      )

    case result do
      {:ok, page} when action == :appointments ->
        json(conn, SchedulerApiWeb.AppointmentJSON.index(%{page: page}))

      {:ok, value} ->
        conn
        |> put_status(if(action in [:add, :create_shift], do: 201, else: 200))
        |> json(%{data: value})

      {:error, :unauthenticated} ->
        conn |> put_status(401) |> json(%{error: "authentication_required"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :persistence_failed} ->
        conn |> put_status(503) |> json(%{error: "operation_unavailable"})

      {:error, e}
      when e in [
             :overlap,
             :assigned_jobs,
             :not_active,
             :already_assigned,
             :not_assigned,
             :already_lead,
             :no_lead,
             :unchanged,
             :ambiguous_team,
             :ineligible_assignment,
             :ineligible_detailer,
             :missing_covering_shift,
             :invalid_appointment
           ] ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(e)})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
