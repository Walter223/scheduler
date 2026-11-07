defmodule SchedulerApi.Repo.Migrations.AddSelfServiceOnboarding do
  use Ecto.Migration

  def up do
    alter table(:login_transactions) do
      add :purpose, :string, null: false, default: "login"
    end

    create constraint(:login_transactions, :login_purpose, check: "purpose IN ('login','signup')")

    alter table(:business_provisioning_intents) do
      add :source, :string, null: false, default: "deployment_operator_command"
      add :activated_pending_account, :boolean, null: false, default: false
    end

    create constraint(:business_provisioning_intents, :provisioning_source,
             check:
               "source IN ('deployment_operator_command','self_service_signup') AND (NOT activated_pending_account OR source='self_service_signup')"
           )

    alter table(:authorization_audit_events) do
      add :activated_pending_account, :boolean, null: false, default: false
    end

    drop constraint(:authorization_audit_events, :audit_source)

    create constraint(:authorization_audit_events, :audit_source,
             check:
               "(action NOT IN ('bootstrap_owner','provision_business') AND source='customer_role_management' AND NOT activated_pending_account) OR (action='bootstrap_owner' AND source='deployment_operator_command' AND actor_user_id IS NULL AND role='business_owner' AND shop_id IS NULL AND NOT activated_pending_account AND (outcome <> 'applied' OR (business_id IS NOT NULL AND target_user_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL))) OR (action='provision_business' AND business_id IS NOT NULL AND shop_id IS NOT NULL AND target_user_id IS NOT NULL AND membership_id IS NOT NULL AND role_assignment_id IS NOT NULL AND role='business_owner' AND outcome='applied' AND reason='changed' AND ((source='deployment_operator_command' AND actor_user_id IS NULL AND NOT activated_pending_account) OR (source='self_service_signup' AND actor_user_id=target_user_id AND actor_user_id IS NOT NULL)))"
           )

    create table(:onboarding_proofs) do
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :token_hash, :binary, null: false
      add :binding_hash, :binary, null: false
      add :csrf_state, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      add :request_hash, :binary
      add :result, :map
      timestamps(type: :utc_datetime)
    end

    create unique_index(:onboarding_proofs, [:token_hash])
    create index(:onboarding_proofs, [:user_id])
    create index(:onboarding_proofs, [:expires_at])

    create constraint(:onboarding_proofs, :proof_hashes,
             check: "octet_length(token_hash)=32 AND octet_length(binding_hash)=32"
           )

    create constraint(:onboarding_proofs, :proof_completion,
             check:
               "(consumed_at IS NULL AND request_hash IS NULL AND result IS NULL) OR (consumed_at IS NOT NULL AND request_hash IS NOT NULL AND octet_length(request_hash)=32 AND result IS NOT NULL)"
           )

    create constraint(:onboarding_proofs, :proof_expiry,
             check: "expires_at=inserted_at + interval '10 minutes'"
           )

    create table(:signup_limits, primary_key: false) do
      add :key, :binary, primary_key: true
      add :window, :utc_datetime, null: false
      add :count, :integer, null: false
    end

    create index(:signup_limits, [:window])
  end

  def down do
    raise Ecto.MigrationError, "Onboarding authorization/audit history requires reviewed rollback"
  end
end
