defmodule SchedulerApiWeb.BusinessOnboardingController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApiWeb.BrowserSession
  def guide_show(conn, _), do: handle(conn, :guide_get)
  def guide_update(conn, _), do: handle(conn, :guide_update)
  def show(conn, _), do: handle(conn, :get)
  def create(conn, _), do: handle(conn, :start)
  def update(conn, _), do: handle(conn, :update)

  defp handle(conn, action) do
    result =
      with {id, ""} when id > 0 <- Integer.parse(conn.path_params["business_id"]),
           true <- conn.query_params == %{},
           true <- action != :start or conn.body_params == %{} do
        credential = %SessionCredential{value: conn.req_cookies[BrowserSession.session_name()]}

        case action do
          :guide_get -> SchedulerApi.BusinessOnboarding.guide(credential, id)
          :guide_update -> SchedulerApi.BusinessOnboarding.guide(credential, id, conn.body_params)
          :get -> SchedulerApi.BusinessOnboarding.get(credential, id)
          :start -> SchedulerApi.BusinessOnboarding.start(credential, id)
          :update -> SchedulerApi.BusinessOnboarding.update(credential, id, conn.body_params)
        end
      else
        _ -> {:error, :invalid_input}
      end

    case result do
      {:ok, data} ->
        json(conn, %{data: data})

      {:error, reason} ->
        {status, error} =
          case reason do
            :invalid_session -> {401, "authentication_required"}
            :forbidden -> {403, "forbidden"}
            :not_started -> {404, "not_started"}
            :operation_unavailable -> {503, "operation_unavailable"}
            r when r in [:revision_conflict, :request_conflict] -> {409, Atom.to_string(r)}
            _ -> {422, "invalid_input"}
          end

        conn |> put_status(status) |> json(%{error: error})
    end
  end
end
