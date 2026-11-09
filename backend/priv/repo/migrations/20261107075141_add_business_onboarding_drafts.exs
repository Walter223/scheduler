defmodule SchedulerApi.Repo.Migrations.AddBusinessOnboardingDrafts do
  use Ecto.Migration

  def up do
    create table(:business_onboarding_drafts) do
      add :business_id, references(:businesses, on_delete: :restrict), null: false
      add :created_by_user_id, references(:users, on_delete: :restrict), null: false
      add :schema_version, :integer, null: false, default: 1
      add :revision, :integer, null: false, default: 0
      add :state, :string, null: false, default: "provisioning_complete"
      add :proposal, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:business_onboarding_drafts, [:business_id])

    create constraint(:business_onboarding_drafts, :onboarding_versions,
             check: "schema_version=1 AND revision>=0"
           )

    create constraint(:business_onboarding_drafts, :onboarding_state,
             check:
               "state IN ('provisioning_complete','locations','employees','services_pricing','branding','review','ready_to_publish','completed')"
           )

    create table(:business_onboarding_events) do
      add :draft_id, references(:business_onboarding_drafts, on_delete: :restrict), null: false
      add :actor_user_id, references(:users, on_delete: :restrict), null: false
      add :revision, :integer, null: false
      add :from_state, :string
      add :to_state, :string, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    create unique_index(:business_onboarding_events, [:draft_id, :revision])

    create table(:business_onboarding_receipts) do
      add :draft_id, references(:business_onboarding_drafts, on_delete: :restrict), null: false
      add :actor_user_id, references(:users, on_delete: :restrict), null: false
      add :request_id, :uuid, null: false
      add :request_hash, :binary, null: false
      add :result, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:business_onboarding_receipts, [:draft_id, :actor_user_id, :request_id])
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS (SELECT 1 FROM business_onboarding_drafts) THEN RAISE EXCEPTION 'Onboarding history requires reviewed rollback'; END IF; END $$"
    drop table(:business_onboarding_receipts)
    drop table(:business_onboarding_events)
    drop table(:business_onboarding_drafts)
  end
end
