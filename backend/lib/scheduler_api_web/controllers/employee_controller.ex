defmodule SchedulerApiWeb.EmployeeController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Employment.Directory
  def index(conn, _), do: read(conn, :directory)
  def shop(conn, _), do: read(conn, :shop)
  def show(conn, _), do: read(conn, :profile)
  def history(conn, _), do: read(conn, :history)
  def period(conn, _), do: read(conn, :period)

  defp read(conn, kind) do
    path = conn.path_params
    resource = if kind == :shop, do: path["shop_id"], else: path["employee_id"]

    result =
      Directory.read(
        conn.assigns[:magnum_session],
        kind,
        path["business_id"],
        resource,
        path["period_id"],
        conn.query_params
      )

    case result do
      {:ok, value} ->
        json(conn, value)

      {:error, :unauthenticated} ->
        conn |> put_status(401) |> json(%{error: "authentication_required"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_options"})
    end
  end
end
