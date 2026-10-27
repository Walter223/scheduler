defmodule SchedulerApi.Catalog.VehicleSize do
  use Ecto.Schema
  import Ecto.Changeset

  schema "vehicle_sizes" do
    belongs_to :business, SchedulerApi.Organizations.Business
    field :name, :string
    field :sort_order, :integer

    has_many :service_prices, SchedulerApi.Catalog.ServicePrice

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(vehicle_size, attrs) do
    vehicle_size
    |> cast(attrs, [:name, :sort_order])
    |> validate_required([:business_id, :name, :sort_order])
    |> validate_number(:sort_order, greater_than: 0)
    |> unique_constraint(:name, name: :vehicle_sizes_business_id_name_index)
    |> unique_constraint(:sort_order,
      name: :vehicle_sizes_business_id_sort_order_index
    )
    |> foreign_key_constraint(:business_id)
    |> check_constraint(:sort_order,
      name: :sort_order_must_be_positive
    )
  end
end
