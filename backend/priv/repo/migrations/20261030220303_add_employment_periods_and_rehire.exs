defmodule SchedulerApi.Repo.Migrations.AddEmploymentPeriodsAndRehire do
  use Ecto.Migration

  def up do
    execute "LOCK TABLE employments IN ACCESS EXCLUSIVE MODE"
    execute "DROP TRIGGER employment_guard ON employments"

    alter table(:employments) do
      add :employee_id, :bigint
    end

    execute "UPDATE employments SET employee_id=id"

    alter table(:employments) do
      modify :employee_id, :bigint, null: false
    end

    execute "ALTER TABLE employments ADD CONSTRAINT employments_employee_identity_fkey FOREIGN KEY(employee_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    drop index(:employments, [:business_id, :user_id],
           name: :employments_business_id_user_id_index
         )

    create unique_index(:employments, [:business_id, :user_id],
             name: :employments_business_id_user_id_index,
             where: "user_id IS NOT NULL AND employee_id=id"
           )

    create unique_index(:employments, [:employee_id],
             where: "status='active'",
             name: :employments_one_active_period
           )

    create index(:employments, [:employee_id, :starts_on, :id])
    create unique_index(:employments, [:id, :employee_id, :business_id])

    execute "ALTER TABLE employments ADD CONSTRAINT employments_periods_no_overlap EXCLUDE USING gist(employee_id WITH =, daterange(starts_on,ends_on,'[]') WITH &&)"

    create table(:employment_rehire_audits) do
      add :actor_user_id, references(:users, on_delete: :restrict), null: false
      add :business_id, :bigint, null: false
      add :employee_id, :bigint, null: false
      add :previous_period_id, :bigint, null: false
      add :period_id, :bigint, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE employment_rehire_audits ADD CONSTRAINT rehire_employee_id_fkey FOREIGN KEY(employee_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    for field <- [:previous_period_id, :period_id] do
      execute "ALTER TABLE employment_rehire_audits ADD CONSTRAINT rehire_#{field}_fkey FOREIGN KEY(#{field},employee_id,business_id) REFERENCES employments(id,employee_id,business_id) ON DELETE RESTRICT"
    end

    create constraint(:employment_rehire_audits, :rehire_distinct_periods,
             check: "previous_period_id<>period_id"
           )

    create unique_index(:employment_rehire_audits, [:period_id])
    create unique_index(:employment_rehire_audits, [:previous_period_id])

    execute "CREATE TRIGGER rehire_audit_immutable BEFORE UPDATE ON employment_rehire_audits FOR EACH ROW EXECUTE FUNCTION magnum_guard_hr_history()"

    execute """
    CREATE OR REPLACE FUNCTION magnum_guard_employment() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (NEW.business_id, NEW.starts_on) IS DISTINCT FROM
           (OLD.business_id, OLD.starts_on) OR
           (OLD.user_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM OLD.user_id) OR
           (OLD.status = 'ended' AND NEW IS DISTINCT FROM OLD) THEN
          RAISE EXCEPTION 'Employment identity, classification and ended history are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'employments_immutable';
        END IF;
      END IF;
      IF NEW.user_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.user_id IS DISTINCT FROM OLD.user_id) AND NOT (TG_OP='INSERT' AND NEW.employee_id IS NOT NULL AND NEW.employee_id<>NEW.id AND EXISTS(SELECT 1 FROM employments root WHERE root.id=NEW.employee_id AND root.employee_id=root.id AND root.business_id=NEW.business_id AND root.user_id IS NOT DISTINCT FROM NEW.user_id)) THEN
        PERFORM 1 FROM users u JOIN business_memberships m ON m.user_id = u.id
          WHERE u.id = NEW.user_id AND u.status = 'active' AND u.email_verified
            AND m.business_id = NEW.business_id AND m.status = 'active' AND m.revoked_at IS NULL
          FOR SHARE OF u, m;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Link requires an eligible existing user and matching active membership'
            USING ERRCODE = '23514', CONSTRAINT = 'employments_link_eligible';
        END IF;
      END IF;
      IF NEW.status = 'ended' AND EXISTS (
        SELECT 1 FROM employment_shop_assignments a WHERE a.employment_id = NEW.id
          AND (a.status = 'active' OR a.ends_on > NEW.ends_on OR a.starts_on > NEW.ends_on)
      ) THEN
        RAISE EXCEPTION 'End shop assignments within the employment dates first'
          USING ERRCODE = '23514', CONSTRAINT = 'employments_assignments_closed';
      END IF;
      IF TG_OP='UPDATE' AND NEW.classification IS DISTINCT FROM OLD.classification AND (
        EXISTS(SELECT 1 FROM appointment_assignments WHERE employment_id=NEW.id AND status='active') OR
        EXISTS(SELECT 1 FROM work_shifts WHERE employment_id=NEW.id AND status='active' AND ends_at>timezone('UTC',statement_timestamp()))
      ) THEN RAISE EXCEPTION 'Resolve outstanding work' USING ERRCODE='23514', CONSTRAINT='employments_outstanding_work'; END IF;
      RETURN NEW;
    END $$
    """

    execute """
    CREATE FUNCTION magnum_guard_employment_period() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE root employments%ROWTYPE; previous employments%ROWTYPE;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
          RAISE EXCEPTION 'Employee identity is immutable' USING ERRCODE='23514',CONSTRAINT='employments_employee_immutable';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.employee_id IS NULL THEN NEW.employee_id:=NEW.id; END IF;
      IF NEW.employee_id=NEW.id THEN RETURN NEW; END IF;
      SELECT * INTO root FROM employments WHERE id=NEW.employee_id FOR UPDATE;
      IF NOT FOUND OR root.employee_id<>root.id OR root.business_id<>NEW.business_id OR root.user_id IS DISTINCT FROM NEW.user_id THEN
        RAISE EXCEPTION 'Invalid employee identity' USING ERRCODE='23514',CONSTRAINT='employments_employee_identity_valid';
      END IF;
      SELECT * INTO previous FROM employments WHERE employee_id=root.id ORDER BY starts_on DESC,id DESC LIMIT 1;
      IF previous.status<>'ended' OR NEW.status<>'active' OR NEW.starts_on<=previous.ends_on OR
         NOT EXISTS(SELECT 1 FROM employment_offboarding_audits WHERE employment_id=previous.id) THEN
        RAISE EXCEPTION 'New period requires completed offboarding and a later start' USING ERRCODE='23514',CONSTRAINT='employments_rehire_valid';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER employment_guard BEFORE INSERT OR UPDATE ON employments FOR EACH ROW EXECUTE FUNCTION magnum_guard_employment()"

    execute "CREATE TRIGGER employment_period_guard BEFORE INSERT OR UPDATE ON employments FOR EACH ROW EXECUTE FUNCTION magnum_guard_employment_period()"
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM employment_rehire_audits) OR EXISTS(SELECT 1 FROM employments WHERE employee_id<>id) THEN RAISE EXCEPTION 'Period history requires reviewed preservation'; END IF; END $$"
    execute "DROP TRIGGER employment_period_guard ON employments"
    execute "DROP FUNCTION magnum_guard_employment_period()"
    drop table(:employment_rehire_audits)
    drop index(:employments, [:id, :employee_id, :business_id])
    execute "ALTER TABLE employments DROP CONSTRAINT employments_periods_no_overlap"
    drop index(:employments, [:employee_id], name: :employments_one_active_period)
    drop index(:employments, [:employee_id, :starts_on, :id])

    drop index(:employments, [:business_id, :user_id],
           name: :employments_business_id_user_id_index
         )

    create unique_index(:employments, [:business_id, :user_id],
             name: :employments_business_id_user_id_index,
             where: "user_id IS NOT NULL"
           )

    execute """
    CREATE OR REPLACE FUNCTION magnum_guard_employment() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (NEW.business_id, NEW.starts_on) IS DISTINCT FROM
           (OLD.business_id, OLD.starts_on) OR
           (OLD.user_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM OLD.user_id) OR
           (OLD.status = 'ended' AND NEW IS DISTINCT FROM OLD) THEN
          RAISE EXCEPTION 'Employment identity, classification and ended history are immutable'
            USING ERRCODE = '23514', CONSTRAINT = 'employments_immutable';
        END IF;
      END IF;
      IF NEW.user_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
        PERFORM 1 FROM users u JOIN business_memberships m ON m.user_id = u.id
          WHERE u.id = NEW.user_id AND u.status = 'active' AND u.email_verified
            AND m.business_id = NEW.business_id AND m.status = 'active' AND m.revoked_at IS NULL
          FOR SHARE OF u, m;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Link requires an eligible existing user and matching active membership'
            USING ERRCODE = '23514', CONSTRAINT = 'employments_link_eligible';
        END IF;
      END IF;
      IF NEW.status = 'ended' AND EXISTS (
        SELECT 1 FROM employment_shop_assignments a WHERE a.employment_id = NEW.id
          AND (a.status = 'active' OR a.ends_on > NEW.ends_on OR a.starts_on > NEW.ends_on)
      ) THEN
        RAISE EXCEPTION 'End shop assignments within the employment dates first'
          USING ERRCODE = '23514', CONSTRAINT = 'employments_assignments_closed';
      END IF;
      IF TG_OP='UPDATE' AND NEW.classification IS DISTINCT FROM OLD.classification AND (
        EXISTS(SELECT 1 FROM appointment_assignments WHERE employment_id=NEW.id AND status='active') OR
        EXISTS(SELECT 1 FROM work_shifts WHERE employment_id=NEW.id AND status='active' AND ends_at>timezone('UTC',statement_timestamp()))
      ) THEN RAISE EXCEPTION 'Resolve outstanding work' USING ERRCODE='23514', CONSTRAINT='employments_outstanding_work'; END IF;
      RETURN NEW;
    END $$
    """

    execute "ALTER TABLE employments DROP CONSTRAINT employments_employee_identity_fkey"

    alter table(:employments) do
      remove :employee_id
    end
  end
end
