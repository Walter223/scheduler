defmodule SchedulerApiWeb.AvailabilityController do
  use SchedulerApiWeb, :controller

  alias SchedulerApi.Appointments.Availability

  def index(conn, params) do
    case Availability.get(params["date"], params["service_price_id"]) do
      {:ok, availability} ->
        render(conn, :index, availability: availability)

      {:error, error} ->
        status = if error.code == :not_found, do: :not_found, else: :unprocessable_entity

        conn
        |> put_status(status)
        |> render(:error, error: error)
    end
  end
end
