defmodule SchedulerApi.Appointments.Appointment do
  use Ecto.Schema

  import Ecto.Changeset

  alias SchedulerApi.Catalog.ServicePrice

  schema "appointments" do
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :service_price, ServicePrice

    field :starts_at, :utc_datetime
    field :duration_minutes, :integer
    field :price_cents, :integer

    field :customer_first_name, :string
    field :customer_last_name, :string
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
    :customer_first_name,
    :customer_last_name,
    :customer_email,
    :customer_phone,
    :vehicle_make,
    :vehicle_model
  ]

  @input_fields [
    :service_price_id,
    :starts_at,
    :notes
    | @customer_fields
  ]

  @doc """
  Validates customer-supplied booking input.

  Price, duration, and status are intentionally not accepted from the client.
  """
  def input_changeset(appointment, attrs) do
    appointment
    |> cast(attrs, @input_fields)
    |> normalize_input()
    |> validate_required([:service_price_id, :starts_at] ++ @customer_fields)
    |> validate_format(
      :customer_email,
      ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
    )
    |> validate_customer_fields()
  end

  @doc """
  Builds the final appointment changeset.

  Price and duration must already have been loaded from the selected
  service price by the Appointments context.
  """
  def changeset(appointment, attrs) do
    appointment
    |> input_changeset(attrs)
    |> force_change(:price_cents, appointment.price_cents)
    |> force_change(:duration_minutes, appointment.duration_minutes)
    |> validate_required([
      :business_id,
      :shop_id,
      :duration_minutes,
      :price_cents,
      :status
    ])
    |> validate_number(:duration_minutes, greater_than: 0)
    |> validate_number(:price_cents, greater_than: 0)
    |> exclusion_constraint(:starts_at,
      name: :appointments_no_active_overlap,
      message: "is no longer available"
    )
    |> foreign_key_constraint(:business_id)
    |> foreign_key_constraint(:shop_id, name: :appointments_shop_business_fkey)
    |> foreign_key_constraint(:service_price_id, name: :appointments_price_ownership_fkey)
    |> foreign_key_constraint(:service_price_id)
    |> check_constraint(
      :duration_minutes,
      name: :appointments_duration_positive
    )
    |> check_constraint(
      :price_cents,
      name: :appointments_price_positive
    )
    |> check_constraint(
      :status,
      name: :appointments_status_valid
    )
    |> validate_customer_constraints()
  end

  defp normalize_input(changeset) do
    changeset
    |> trim_field(:customer_first_name)
    |> trim_field(:customer_last_name)
    |> trim_field(:customer_phone)
    |> trim_field(:vehicle_make)
    |> trim_field(:vehicle_model)
    |> normalize_email()
    |> normalize_notes()
  end

  defp trim_field(changeset, field) do
    update_change(changeset, field, &trim_string/1)
  end

  defp normalize_email(changeset) do
    update_change(changeset, :customer_email, fn value ->
      value
      |> trim_string()
      |> downcase_string()
    end)
  end

  defp normalize_notes(changeset) do
    update_change(changeset, :notes, fn value ->
      case trim_string(value) do
        "" -> nil
        value -> value
      end
    end)
  end

  defp trim_string(value) when is_binary(value),
    do: String.trim(value)

  defp trim_string(value),
    do: value

  defp downcase_string(value) when is_binary(value),
    do: String.downcase(value)

  defp downcase_string(value),
    do: value

  defp validate_customer_fields(changeset) do
    Enum.reduce(@customer_fields, changeset, fn field, acc ->
      max_length = if field in [:customer_first_name, :customer_last_name], do: 100, else: 255
      validate_length(acc, field, max: max_length)
    end)
  end

  defp validate_customer_constraints(changeset) do
    Enum.reduce(@customer_fields, changeset, fn field, acc ->
      check_constraint(
        acc,
        field,
        name: "appointments_#{field}_not_blank"
      )
    end)
  end
end
