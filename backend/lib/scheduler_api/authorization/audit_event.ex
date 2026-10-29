defmodule SchedulerApi.Authorization.AuditEvent do
  use Ecto.Schema

  schema "authorization_audit_events" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :target_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :membership, SchedulerApi.Organizations.BusinessMembership
    belongs_to :role_assignment, SchedulerApi.Organizations.RoleAssignment
    belongs_to :shop, SchedulerApi.Organizations.Shop
    field :role, Ecto.Enum, values: [:business_owner, :business_manager, :shop_manager, :employee]

    field :action, Ecto.Enum,
      values: [:grant_role, :revoke_role, :revoke_membership, :reactivate_membership]

    field :outcome, Ecto.Enum, values: [:applied, :denied, :noop]

    field :reason, Ecto.Enum,
      values: [
        :changed,
        :forbidden,
        :invalid_target,
        :invalid_role,
        :invalid_scope,
        :duplicate_grant,
        :last_owner,
        :ineligible_target,
        :already_revoked,
        :already_active
      ]

    field :occurred_at, :utc_datetime
  end
end
