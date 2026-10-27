defmodule SchedulerApi.Catalog.ServicePrice do
  use Ecto.Schema
  import Ecto.Changeset

  alias SchedulerApi.Catalog.{Service, VehicleSize}

  schema "service_prices" do
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    field :price_cents, :integer
    field :duration_minutes, :integer

    belongs_to :service, Service
    belongs_to :vehicle_size, VehicleSize

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service_price, attrs) do
    service_price
    |> cast(attrs, [:price_cents, :duration_minutes, :service_id, :vehicle_size_id])
    |> validate_required([
      :business_id,
      :shop_id,
      :price_cents,
      :duration_minutes,
      :service_id,
      :vehicle_size_id
    ])
    |> validate_number(:price_cents, greater_than: 0)
    |> foreign_key_constraint(:business_id)
    |> foreign_key_constraint(:shop_id, name: :service_prices_shop_business_fkey)
    |> foreign_key_constraint(:service_id, name: :service_prices_service_business_fkey)
    |> foreign_key_constraint(:vehicle_size_id, name: :service_prices_vehicle_size_business_fkey)
    |> foreign_key_constraint(:service_id)
    |> foreign_key_constraint(:vehicle_size_id)
    |> unique_constraint(
      [:service_id, :vehicle_size_id],
      name: :service_prices_shop_service_size_index
    )
    |> check_constraint(:price_cents,
      name: :price_cents_must_be_positive
    )
  end
end
