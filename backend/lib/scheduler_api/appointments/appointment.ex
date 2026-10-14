defmodule SchedulerApi.Appointments.Appointment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "appointments" do
    belongs_to :service_price, SchedulerApi.Catalog.ServicePrice
    field :starts_at, :utc_datetime
    field :duration_minutes, :integer
    field :price_cents, :integer
    field :customer_name, :string
    field :customer_email, :string
    field :customer_phone, :string
    field :vehicle_make, :string
    field :vehicle_model, :string
    field :notes, :string

    field :status, Ecto.Enum,
      values: [:pending, :confirmed, :completed, :cancelled],
      default: :pending

    timestamps(type: :utc_datetime)
  end

  @customer_fields [
    :customer_name,
    :customer_email,
    :customer_phone,
    :vehicle_make,
    :vehicle_model
  ]

  @doc "Validates booking input; status and price/duration snapshots are server-managed."
  def changeset(appointment, attrs) do
    appointment
    |> cast(attrs, [:service_price_id, :starts_at, :notes] ++ @customer_fields)
    |> force_change(:price_cents, appointment.price_cents)
    |> force_change(:duration_minutes, appointment.duration_minutes)
    |> validate_required(
      [:service_price_id, :starts_at, :duration_minutes, :price_cents, :status] ++
        @customer_fields
    )
    |> validate_format(:customer_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> validate_number(:duration_minutes, greater_than: 0)
    |> validate_number(:price_cents, greater_than: 0)
    |> foreign_key_constraint(:service_price_id)
    |> check_constraint(:duration_minutes, name: :appointments_duration_positive)
    |> check_constraint(:price_cents, name: :appointments_price_positive)
    |> check_constraint(:status, name: :appointments_status_valid)
    |> validate_customer_fields()
  end

  defp validate_customer_fields(changeset) do
    Enum.reduce(@customer_fields, changeset, fn field, acc ->
      acc
      |> validate_length(field, max: 255)
      |> check_constraint(field, name: "appointments_#{field}_not_blank")
    end)
  end
end
