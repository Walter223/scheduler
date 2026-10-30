defmodule SchedulerApi.Repo.Migrations.AddEmploymentOffboardingAudits do
  use Ecto.Migration

  def up do
    create table(:employment_offboarding_audits) do
      add :actor_user_id, references(:users, on_delete: :restrict), null: false
      add :business_id, :bigint, null: false
      add :employment_id, :bigint, null: false
      add :ended_on, :date, null: false
      add :jobs_removed, :integer, null: false
      add :shifts_cancelled, :integer, null: false
      add :assignments_ended, :integer, null: false
      add :membership_id, :bigint
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE employment_offboarding_audits ADD CONSTRAINT offboarding_employment_fkey FOREIGN KEY(employment_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE employment_offboarding_audits ADD CONSTRAINT offboarding_membership_fkey FOREIGN KEY(membership_id,business_id) REFERENCES business_memberships(id,business_id) ON DELETE RESTRICT"

    create unique_index(:employment_offboarding_audits, [:employment_id])

    create constraint(:employment_offboarding_audits, :offboarding_counts_valid,
             check: "jobs_removed>=0 AND shifts_cancelled>=0 AND assignments_ended>=0"
           )

    execute "CREATE TRIGGER offboarding_audit_immutable BEFORE UPDATE ON employment_offboarding_audits FOR EACH ROW EXECUTE FUNCTION magnum_guard_hr_history()"
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM employment_offboarding_audits) THEN RAISE EXCEPTION 'Offboarding history requires reviewed preservation'; END IF; END $$"
    drop table(:employment_offboarding_audits)
  end
end
