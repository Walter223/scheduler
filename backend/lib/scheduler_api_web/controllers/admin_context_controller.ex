defmodule SchedulerApiWeb.AdminContextController do
  use SchedulerApiWeb, :controller

  def index(conn, _) do
    if map_size(conn.query_params) == 0 do
      json(conn, %{
        businesses: SchedulerApi.Authorization.admin_contexts(conn.assigns.magnum_session.user)
      })
    else
      conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
