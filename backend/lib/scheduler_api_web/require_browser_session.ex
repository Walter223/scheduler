defmodule SchedulerApiWeb.RequireBrowserSession do
  @moduledoc "Private API session boundary; authentication alone grants no tenant access."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> SchedulerApiWeb.BrowserSession.call([])

    if conn.assigns.magnum_session do
      conn
    else
      conn
      |> put_status(401)
      |> Phoenix.Controller.json(%{error: "authentication_required"})
      |> halt()
    end
  end
end
