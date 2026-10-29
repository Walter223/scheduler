defmodule SchedulerApi.Organizations.RoleAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  @roles [:business_owner, :business_manager, :shop_manager, :employee]
  def roles, do: @roles

  schema "role_assignments" do
    belongs_to :membership, SchedulerApi.Organizations.BusinessMembership
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    field :role, Ecto.Enum, values: @roles
    field :status, Ecto.Enum, values: [:active, :revoked], default: :active
    field :revoked_at, :utc_datetime
    belongs_to :revoked_by_user, SchedulerApi.Accounts.User
    field :revocation_reason, Ecto.Enum, values: [:manual, :membership_revoked]
    timestamps(type: :utc_datetime)
  end

  # Trusted code must supply persisted ownership; no request-facing grant API.
  @doc false
  def creation_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:role])
    |> validate_required([:membership_id, :business_id, :role])
    |> check_constraint(:role, name: :role_assignments_role_scope)
    |> check_constraint(:membership_id, name: :role_assignments_active_membership)
    |> foreign_key_constraint(:membership_id, name: :role_assignments_membership_business_fkey)
    |> foreign_key_constraint(:shop_id, name: :role_assignments_shop_business_fkey)
    |> unique_constraint(:role, name: :role_assignments_active_business_unique)
    |> unique_constraint(:role, name: :role_assignments_active_shop_unique)
  end
end
