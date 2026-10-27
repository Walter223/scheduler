defmodule SchedulerApiWeb.AppointmentController do
  use SchedulerApiWeb, :controller

  alias SchedulerApi.Appointments

  # Development-only: this action exposes PII and has no admin access controls yet.
  def index(conn, params) do
    opts = [limit: parse_limit(Map.get(params, "limit", 50)), cursor: Map.get(params, "cursor")]

    case Appointments.list_upcoming_appointments(opts) do
      {:ok, page} ->
        render(conn, :index, page: page)

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:list_error, error: error)
    end
  end

  def create(conn, params) do
    case Appointments.create_appointment(params) do
      {:ok, appointment} ->
        conn
        |> put_status(:created)
        |> render(:show, appointment: appointment)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  # Translate HTTP strings only; the context owns range validation. Bounding
  # parsing also avoids converting arbitrarily large query strings to integers.
  defp parse_limit(value) when is_binary(value) and byte_size(value) <= 32 do
    case Integer.parse(value) do
      {limit, ""} -> limit
      _ -> value
    end
  end

  defp parse_limit(value), do: value
end
