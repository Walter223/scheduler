defmodule SchedulerApi.Appointments do
  @moduledoc """
  Creates and retrieves appointments using catalog price and duration snapshots.
  """

  import Ecto.Query

  alias SchedulerApi.Repo
  alias SchedulerApi.Catalog.ServicePrice
  alias SchedulerApi.Appointments.{Appointment, Availability}

  @schedule_lock_namespace 0x4D41474E
  @shared_schedule_id 1

  @doc """
  Returns appointments ordered by start time and ID.
  """
  def list_appointments do
    Repo.all(
      from a in Appointment,
        order_by: [asc: a.starts_at, asc: a.id]
    )
  end

  @doc """
  Returns an appointment, or nil when absent.
  """
  def get_appointment(id) do
    Repo.get(Appointment, id)
  end

  @doc """
  Returns an appointment or raises Ecto.NoResultsError.
  """
  def get_appointment!(id) do
    Repo.get!(Appointment, id)
  end

  @doc """
  Creates a pending appointment.

  Customer-supplied price, duration, and status are ignored.

  A transaction-level advisory lock serializes creation for the shared schedule
  before availability is rechecked and the appointment is inserted. The PostgreSQL
  exclusion constraint remains the final overlap safety net, including buffers.

  Price and duration are copied from the selected service price and stored
  on the appointment as historical snapshots.
  """
  def create_appointment(attrs) do
    input_changeset =
      Appointment.input_changeset(%Appointment{}, attrs)

    if input_changeset.valid? do
      create_from_service_price(input_changeset, attrs)
    else
      {:error, input_changeset}
    end
  end

  defp create_from_service_price(input_changeset, attrs) do
    service_price_id =
      Ecto.Changeset.get_field(
        input_changeset,
        :service_price_id
      )

    Repo.transaction(fn ->
      # Concurrent GiST exclusion checks can deadlock after both requests pass
      # availability. Serialize the one shared schedule before taking catalog
      # locks, rechecking availability, or inserting. The lock is automatically
      # released on commit/rollback and must not be keyed by service_price_id.
      # With multiple detailers/bays, replace the shared ID with the resource/
      # employee ID (and scope availability and exclusion protection accordingly).
      Repo.query!(
        "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
        [@schedule_lock_namespace, @shared_schedule_id]
      )

      service_price =
        Repo.one(
          from price in ServicePrice,
            where: price.id == ^service_price_id,
            lock: "FOR SHARE"
        )

      case service_price do
        nil ->
          input_changeset
          |> Ecto.Changeset.add_error(
            :service_price_id,
            "does not exist"
          )
          |> Repo.rollback()

        service_price ->
          insert_appointment(service_price, attrs)
      end
    end)
  end

  defp insert_appointment(service_price, attrs) do
    appointment =
      %Appointment{
        price_cents: service_price.price_cents,
        duration_minutes: service_price.duration_minutes
      }

    changeset =
      Appointment.changeset(
        appointment,
        attrs
      )

    starts_at = Ecto.Changeset.get_field(changeset, :starts_at)

    case Availability.validate_slot(starts_at, service_price.duration_minutes) do
      :ok ->
        :ok

      {:error, error} ->
        changeset
        |> Ecto.Changeset.add_error(:starts_at, error.message)
        |> Repo.rollback()
    end

    # Keep the exclusion constraint as defense in depth, including for writes
    # that bypass this context and its shared scheduling lock.
    case Repo.insert(changeset) do
      {:ok, appointment} ->
        appointment

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end
end
