defmodule SchedulerApi.Repo.Migrations.SupportOwnerBootstrapAudit do
  use Ecto.Migration
  @actions "'grant_role','revoke_role','revoke_membership','reactivate_membership'"
  @reasons "'changed','forbidden','invalid_target','invalid_role','invalid_scope','duplicate_grant','last_owner','ineligible_target','already_revoked','already_active'"
  @bootstrap_reasons "'invalid_business','invalid_identity','existing_owner_history','inactive_business','inactive_membership'"

  def up do
    alter table(:authorization_audit_events) do
      add :source, :string, null: false, default: "customer_role_management"
    end

    drop constraint(:authorization_audit_events, :audit_action)
    drop constraint(:authorization_audit_events, :audit_reason)

    create constraint(:authorization_audit_events, :audit_action,
             check: "action IN (#{@actions},'bootstrap_owner')"
           )

    create constraint(:authorization_audit_events, :audit_reason,
             check: "reason IN (#{@reasons},#{@bootstrap_reasons})"
           )

    create constraint(:authorization_audit_events, :audit_source,
             check:
               "(action <> 'bootstrap_owner' AND source = 'customer_role_management') OR (action = 'bootstrap_owner' AND source = 'deployment_operator_command' AND actor_user_id IS NULL AND role = 'business_owner' AND shop_id IS NULL AND (outcome <> 'applied' OR (business_id IS NOT NULL AND target_user_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL)))"
           )
  end

  def down do
    # Fail rather than discard or mislabel committed bootstrap audit history.
    execute "DO $$ BEGIN IF EXISTS (SELECT 1 FROM authorization_audit_events WHERE action='bootstrap_owner') THEN RAISE EXCEPTION 'Bootstrap audit history requires a reviewed rollback'; END IF; END $$"
    drop constraint(:authorization_audit_events, :audit_source)
    drop constraint(:authorization_audit_events, :audit_action)
    drop constraint(:authorization_audit_events, :audit_reason)

    create constraint(:authorization_audit_events, :audit_action,
             check: "action IN (#{@actions})"
           )

    create constraint(:authorization_audit_events, :audit_reason,
             check: "reason IN (#{@reasons})"
           )

    alter table(:authorization_audit_events) do
      remove :source
    end
  end
end
