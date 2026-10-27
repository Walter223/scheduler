defmodule SchedulerApiWeb.AppointmentJSON do
  def show(%{appointment: appointment}) do
    %{
      appointment: data(appointment)
    }
  end

  def error(%{changeset: changeset}) do
    %{
      errors:
        Ecto.Changeset.traverse_errors(
          changeset,
          fn {message, opts} ->
            Regex.replace(
              ~r"%{(\w+)}",
              message,
              fn _, key ->
                opts
                |> Keyword.get(String.to_existing_atom(key), key)
                |> to_string()
              end
            )
          end
        )
    }
  end

  defp data(appointment) do
    %{
      id: appointment.id,
      service_price_id: appointment.service_price_id,
      starts_at: appointment.starts_at,
      duration_minutes: appointment.duration_minutes,
      price_cents: appointment.price_cents,
      customer_first_name: appointment.customer_first_name,
      customer_last_name: appointment.customer_last_name,
      customer_email: appointment.customer_email,
      customer_phone: appointment.customer_phone,
      vehicle_make: appointment.vehicle_make,
      vehicle_model: appointment.vehicle_model,
      notes: appointment.notes,
      status: appointment.status
    }
  end
end
