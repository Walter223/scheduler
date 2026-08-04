defmodule SchedulerApi.Catalog.ServicePrice do
  use Ecto.Schema
  import Ecto.Changeset

  alias SchedulerApi.Catalog.{Service, VehicleSize}

  schema "service_prices" do
    field :price_cents, :integer

    belongs_to :service, Service
    belongs_to :vehicle_size, VehicleSize

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service_price, attrs) do
    service_price
    |> cast(attrs, [:price_cents, :service_id, :vehicle_size_id])
    |> validate_required([:price_cents, :service_id, :vehicle_size_id])
    |> validate_number(:price_cents, greater_than: 0)
    |> foreign_key_constraint(:service_id)
    |> foreign_key_constraint(:vehicle_size_id)
    |> unique_constraint(
      [:service_id, :vehicle_size_id],
      name: :service_prices_service_id_vehicle_size_id_index
    )
    |> check_constraint(:price_cents,
      name: :price_cents_must_be_positive
    )
  end
end
