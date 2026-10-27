defmodule SchedulerApi.Catalog.Service do
  use Ecto.Schema
  import Ecto.Changeset

  schema "services" do
    belongs_to :business, SchedulerApi.Organizations.Business
    field :name, :string
    field :description, :string

    has_many :service_prices, SchedulerApi.Catalog.ServicePrice

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :description])
    |> validate_required([:business_id, :name, :description])
    |> unique_constraint(:name, name: :services_business_id_name_index)
    |> foreign_key_constraint(:business_id)
  end
end
