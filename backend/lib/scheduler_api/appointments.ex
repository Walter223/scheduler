defmodule SchedulerApi.Appointments do
  @moduledoc "Creates bookings with catalog price and duration snapshots."

  import Ecto.Query
  alias SchedulerApi.Repo
  alias SchedulerApi.Catalog.ServicePrice
  alias SchedulerApi.Appointments.Appointment

  @doc "Returns appointments ordered by start time and ID."
  def list_appointments do
    Repo.all(from a in Appointment, order_by: [asc: a.starts_at, asc: a.id])
  end

  @doc "Returns an appointment, or nil when absent."
  def get_appointment(id), do: Repo.get(Appointment, id)

  @doc "Returns an appointment or raises Ecto.NoResultsError."
  def get_appointment!(id), do: Repo.get!(Appointment, id)

  @doc """
  Creates a pending appointment from service_price_id and customer/vehicle input.
  Caller-supplied price, duration, and status are ignored. The selected catalog
  row is locked during creation so its price and duration form one snapshot.
  Returns {:ok, appointment} or {:error, changeset}.
  """
  def create_appointment(attrs) do
    input = Appointment.changeset(%Appointment{}, attrs)
    service_price_id = Ecto.Changeset.get_field(input, :service_price_id)

    Repo.transaction(fn ->
      service_price =
        if is_integer(service_price_id) do
          Repo.one(from p in ServicePrice, where: p.id == ^service_price_id, lock: "FOR SHARE")
        end

      changeset =
        if service_price do
          %Appointment{
            price_cents: service_price.price_cents,
            duration_minutes: service_price.duration_minutes
          }
          |> Appointment.changeset(attrs)
        else
          Ecto.Changeset.add_error(input, :service_price_id, "does not exist")
        end

      case Repo.insert(changeset) do
        {:ok, appointment} -> appointment
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
