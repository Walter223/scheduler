defmodule SchedulerApiWeb.CalendarController do
  use SchedulerApiWeb, :controller

  def index(conn, _) do
    with {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 <-
           Integer.parse(conn.path_params["business_id"]),
         {:ok, data} <-
           SchedulerApi.Appointments.Calendar.read(
             conn.assigns.magnum_session.user,
             id,
             conn.query_params
           ) do
      json(conn, %{data: data})
    else
      {:error, :forbidden} -> conn |> put_status(403) |> json(%{error: "forbidden"})
      _ -> conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end
end
