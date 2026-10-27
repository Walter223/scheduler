defmodule SchedulerApi.Organizations.Business do
  use Ecto.Schema
  import Ecto.Changeset

  schema "businesses" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    has_many :shops, SchedulerApi.Organizations.Shop
    timestamps(type: :utc_datetime)
  end

  def changeset(business, attrs) do
    business
    |> cast(attrs, [:name, :slug, :status])
    |> validate_required([:name, :slug, :status])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/)
    |> unique_constraint(:slug, name: :businesses_slug_key)
  end
end
