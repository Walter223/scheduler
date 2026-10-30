defmodule SchedulerApi.Authorization.AuditEvent do
  use Ecto.Schema

  schema "authorization_audit_events" do
    field :source, Ecto.Enum,
      values: [:customer_role_management, :deployment_operator_command],
      default: :customer_role_management

    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :target_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :membership, SchedulerApi.Organizations.BusinessMembership
    belongs_to :role_assignment, SchedulerApi.Organizations.RoleAssignment
    belongs_to :shop, SchedulerApi.Organizations.Shop
    field :role, Ecto.Enum, values: [:business_owner, :business_manager, :shop_manager, :employee]

    field :action, Ecto.Enum,
      values: [
        :grant_role,
        :revoke_role,
        :revoke_membership,
        :reactivate_membership,
        :bootstrap_owner
      ]

    field :outcome, Ecto.Enum, values: [:applied, :denied, :noop]

    field :reason, Ecto.Enum,
      values: [
        :invalid_business,
        :invalid_identity,
        :existing_owner_history,
        :inactive_business,
        :inactive_membership,
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
