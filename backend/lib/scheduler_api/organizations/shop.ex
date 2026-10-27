defmodule SchedulerApi.Organizations.Shop do
  use Ecto.Schema
  import Ecto.Changeset

  schema "shops" do
    belongs_to :business, SchedulerApi.Organizations.Business
    field :name, :string
    field :slug, :string
    field :timezone, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    timestamps(type: :utc_datetime)
  end

  # Ownership is assigned by trusted callers on the struct, never from attrs.
  def changeset(shop, attrs) do
    shop
    |> cast(attrs, [:name, :slug, :timezone, :status])
    |> validate_required([:business_id, :name, :slug, :timezone, :status])
    |> validate_length(:name, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_length(:timezone, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/)
    |> unique_constraint([:business_id, :slug], name: :shops_business_id_slug_key)
    |> foreign_key_constraint(:business_id)
  end
end
