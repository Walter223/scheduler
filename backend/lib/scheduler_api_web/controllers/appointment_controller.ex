defmodule SchedulerApiWeb.AppointmentController do
  use SchedulerApiWeb, :controller

  alias SchedulerApi.Appointments

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
end
