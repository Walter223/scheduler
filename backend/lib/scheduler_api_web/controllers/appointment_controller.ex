defmodule SchedulerApiWeb.AppointmentController do
  use SchedulerApiWeb, :controller

  alias SchedulerApi.Appointments

  def index(conn, params) do
    opts = [limit: parse_limit(Map.get(params, "limit", 50)), cursor: Map.get(params, "cursor")]

    result =
      case conn.assigns[:magnum_session] do
        %SchedulerApi.Accounts.WebSession{} = session ->
          if Enum.any?(["shop_id", "business_id", "user_id"], &Map.has_key?(params, &1)),
            do: {:error, :forbidden},
            else: Appointments.list_authorized_upcoming_appointments(session, opts)

        _ ->
          {:error, :unauthenticated}
      end

    case result do
      {:ok, page} ->
        render(conn, :index, page: page)

      {:error, :unauthenticated} ->
        conn |> put_status(401) |> json(%{error: "authentication_required"})

      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden"})

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
