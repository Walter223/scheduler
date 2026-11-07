defmodule SchedulerApi.Repo.Migrations.AddBusinessProvisioningIntents do
  use Ecto.Migration

  @actions "'grant_role','revoke_role','revoke_membership','reactivate_membership','bootstrap_owner'"
  @old_source "(action <> 'bootstrap_owner' AND source = 'customer_role_management') OR (action = 'bootstrap_owner' AND source = 'deployment_operator_command' AND actor_user_id IS NULL AND role = 'business_owner' AND shop_id IS NULL AND (outcome <> 'applied' OR (business_id IS NOT NULL AND target_user_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL)))"

  def up do
    create table(:business_provisioning_intents) do
      add :owner_id, references(:users, on_delete: :restrict), null: false
      add :credential_hash, :binary, null: false
      add :business_name, :string, null: false
      add :business_slug, :string, null: false
      add :shop_name, :string, null: false
      add :shop_slug, :string, null: false
      add :timezone, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :business_id, references(:businesses, on_delete: :restrict)
      add :shop_id, references(:shops, on_delete: :restrict)
      add :membership_id, references(:business_memberships, on_delete: :restrict)
      add :role_assignment_id, references(:role_assignments, on_delete: :restrict)
      add :audit_event_id, references(:authorization_audit_events, on_delete: :restrict)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:business_provisioning_intents, [:credential_hash])
    create unique_index(:business_provisioning_intents, [:business_id])
    create index(:business_provisioning_intents, [:owner_id])
    create index(:business_provisioning_intents, [:expires_at])

    create constraint(:business_provisioning_intents, :provisioning_hash,
             check: "octet_length(credential_hash) = 32"
           )

    create constraint(:business_provisioning_intents, :provisioning_expiry,
             check: "expires_at = inserted_at + interval '10 minutes'"
           )

    create constraint(:business_provisioning_intents, :provisioning_completion,
             check:
               "(completed_at IS NULL AND business_id IS NULL AND shop_id IS NULL AND membership_id IS NULL AND role_assignment_id IS NULL AND audit_event_id IS NULL) OR (completed_at IS NOT NULL AND completed_at >= inserted_at AND completed_at < expires_at AND business_id IS NOT NULL AND shop_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL AND audit_event_id IS NOT NULL)"
           )

    create constraint(:business_provisioning_intents, :provisioning_names,
             check:
               "length(btrim(business_name)) > 0 AND length(btrim(shop_name)) > 0 AND business_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND shop_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'"
           )

    execute "ALTER TABLE business_provisioning_intents ADD CONSTRAINT provisioning_shop_business_fkey FOREIGN KEY (shop_id, business_id) REFERENCES shops(id, business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE business_provisioning_intents ADD CONSTRAINT provisioning_membership_business_fkey FOREIGN KEY (membership_id, business_id) REFERENCES business_memberships(id, business_id) ON DELETE RESTRICT"

    drop constraint(:authorization_audit_events, :audit_action)
    drop constraint(:authorization_audit_events, :audit_source)

    create constraint(:authorization_audit_events, :audit_action,
             check: "action IN (#{@actions},'provision_business')"
           )

    create constraint(:authorization_audit_events, :audit_source,
             check:
               "(action <> 'provision_business' AND (#{@old_source})) OR (action = 'provision_business' AND source = 'deployment_operator_command' AND actor_user_id IS NULL AND target_user_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL AND role = 'business_owner' AND outcome = 'applied' AND reason = 'changed')"
           )
  end

  def down do
    # Never erase or mislabel committed provisioning/audit history on rollback.
    execute "DO $$ BEGIN IF EXISTS (SELECT 1 FROM business_provisioning_intents) OR EXISTS (SELECT 1 FROM authorization_audit_events WHERE action='provision_business') THEN RAISE EXCEPTION 'Provisioning history requires a reviewed rollback'; END IF; END $$"
    drop table(:business_provisioning_intents)
    drop constraint(:authorization_audit_events, :audit_source)
    drop constraint(:authorization_audit_events, :audit_action)

    create constraint(:authorization_audit_events, :audit_action,
             check: "action IN (#{@actions})"
           )

    create constraint(:authorization_audit_events, :audit_source, check: @old_source)
  end
end
