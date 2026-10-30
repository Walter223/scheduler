defmodule SchedulerApi.Employment.ShopAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "employment_shop_assignments" do
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    field :status, Ecto.Enum, values: [:active, :ended], default: :active
    field :starts_on, :date
    field :ends_on, :date
    timestamps(type: :utc_datetime)
  end

  @doc false
  def creation_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:starts_on])
    |> validate_required([:employment_id, :business_id, :shop_id, :starts_on])
    |> add_constraints()
  end

  @doc false
  def end_changeset(assignment, date) do
    assignment |> change(status: :ended, ends_on: date) |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:employment_id,
      name: :employment_shop_assignments_employment_business_fkey
    )
    |> foreign_key_constraint(:shop_id, name: :employment_shop_assignments_shop_business_fkey)
    |> unique_constraint(:shop_id, name: :employment_shop_assignments_active_unique)
    |> check_constraint(:starts_on, name: :employment_shop_assignments_employment_dates)
    |> check_constraint(:ends_on, name: :employment_shop_assignments_lifecycle)
    |> check_constraint(:shop_id, name: :employment_shop_assignments_immutable)
  end
end
