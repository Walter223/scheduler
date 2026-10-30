defmodule SchedulerApiWeb.EmployeeWriteController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApiWeb.BrowserSession

  for action <- [:create, :contact, :classification, :assign_shop, :end_shop, :terminate, :rehire] do
    def unquote(action)(conn, _), do: write(conn, unquote(action))
  end

  defp write(conn, action) do
    # Only the already authenticated cookie becomes a domain credential. Never
    # accept a submitted credential, actor/user ID or session metadata.
    credential = %SessionCredential{value: conn.req_cookies[BrowserSession.session_name()]}

    result =
      SchedulerApi.Employment.HTTPWrites.run(
        action,
        credential,
        conn.assigns.magnum_session.user,
        conn.path_params,
        conn.body_params,
        conn.query_params
      )

    case result do
      {:ok, value} ->
        conn
        |> put_status(if(action in [:create, :rehire, :assign_shop], do: 201, else: 200))
        |> json(%{data: value})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, :persistence_failed} ->
        conn |> put_status(503) |> json(%{error: "operation_unavailable"})

      {:error, reason}
      when reason in [
             :already_assigned,
             :assignment_ended,
             :employment_ended,
             :outstanding_work,
             :work_in_progress,
             :future_assignment_dates,
             :last_owner,
             :legacy_termination_requires_review,
             :not_latest_ended_period,
             :offboarding_required,
             :unchanged
           ] ->
        conn |> put_status(409) |> json(%{error: Atom.to_string(reason)})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
