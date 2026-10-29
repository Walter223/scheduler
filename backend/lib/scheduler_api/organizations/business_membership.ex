defmodule SchedulerApi.Organizations.BusinessMembership do
  use Ecto.Schema
  import Ecto.Changeset

  schema "business_memberships" do
    belongs_to :user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    field :status, Ecto.Enum, values: [:active, :revoked], default: :active
    field :revoked_at, :utc_datetime
    belongs_to :revoked_by_user, SchedulerApi.Accounts.User
    field :revocation_reason, Ecto.Enum, values: [:manual, :membership_revoked]

    has_many :role_assignments, SchedulerApi.Organizations.RoleAssignment,
      foreign_key: :membership_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def creation_changeset(membership) do
    membership
    |> change()
    |> validate_required([:user_id, :business_id])
    |> unique_constraint([:user_id, :business_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:business_id)
  end
end
