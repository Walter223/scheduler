defmodule SchedulerApi.Repo.Migrations.AddAuthorizationAuditEvents do
  use Ecto.Migration

  def change do
    create table(:authorization_audit_events) do
      add :actor_user_id, references(:users, on_delete: :restrict)
      add :target_user_id, references(:users, on_delete: :restrict)
      add :business_id, references(:businesses, on_delete: :restrict)
      add :membership_id, references(:business_memberships, on_delete: :restrict)
      add :role_assignment_id, references(:role_assignments, on_delete: :restrict)
      add :shop_id, references(:shops, on_delete: :restrict)
      add :role, :string
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    create index(:authorization_audit_events, [:business_id, :occurred_at, :id])

    create constraint(:authorization_audit_events, :audit_role,
             check:
               "role IS NULL OR role IN ('business_owner','business_manager','shop_manager','employee')"
           )

    create constraint(:authorization_audit_events, :audit_action,
             check:
               "action IN ('grant_role','revoke_role','revoke_membership','reactivate_membership')"
           )

    create constraint(:authorization_audit_events, :audit_outcome,
             check: "outcome IN ('applied','denied','noop')"
           )

    create constraint(:authorization_audit_events, :audit_reason,
             check:
               "reason IN ('changed','forbidden','invalid_target','invalid_role','invalid_scope','duplicate_grant','last_owner','ineligible_target','already_revoked','already_active')"
           )
  end
end
