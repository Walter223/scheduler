defmodule SchedulerApi.Repo.Migrations.AddEmploymentHrAdministration do
  use Ecto.Migration

  def up do
    create table(:employment_classification_history) do
      add :employment_id, :bigint, null: false
      add :business_id, :bigint, null: false
      add :previous_classification, :string, size: 32
      add :classification, :string, size: 32, null: false
      add :source, :string, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE employment_classification_history ADD CONSTRAINT employment_classification_parent_fkey FOREIGN KEY (employment_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    create unique_index(:employment_classification_history, [:id, :employment_id, :business_id])
    create index(:employment_classification_history, [:employment_id, :classification])

    create constraint(
             :employment_classification_history,
             :employment_classification_history_valid,
             check:
               "classification IN ('detailer','shop_manager','business_manager','business_owner') AND (previous_classification IS NULL OR previous_classification IN ('detailer','shop_manager','business_manager','business_owner')) AND ((source IN ('baseline','created') AND previous_classification IS NULL) OR (source='changed' AND previous_classification IS NOT NULL AND previous_classification<>classification))"
           )

    # Record only the classification observed now, never invent earlier history.
    execute "INSERT INTO employment_classification_history(employment_id,business_id,classification,source,occurred_at) SELECT id,business_id,classification,'baseline',timezone('UTC',statement_timestamp()) FROM employments"

    create table(:employment_hr_audit_events) do
      add :actor_user_id, references(:users, on_delete: :restrict)
      add :business_id, references(:businesses, on_delete: :restrict)
      add :employment_id, :bigint
      add :assignment_id, :bigint
      add :shop_id, :bigint
      add :classification_history_id, :bigint
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string, size: 40, null: false
      add :changed_fields, {:array, :string}, null: false, default: []
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT employment_hr_parent_fkey FOREIGN KEY (employment_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT employment_hr_assignment_fkey FOREIGN KEY (assignment_id,employment_id,business_id,shop_id) REFERENCES employment_shop_assignments(id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    execute "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT employment_hr_history_fkey FOREIGN KEY (classification_history_id,employment_id,business_id) REFERENCES employment_classification_history(id,employment_id,business_id) ON DELETE RESTRICT"

    create index(:employment_hr_audit_events, [:business_id, :employment_id, :occurred_at, :id])

    create unique_index(:employment_hr_audit_events, [:classification_history_id],
             where: "classification_history_id IS NOT NULL"
           )

    create constraint(:employment_hr_audit_events, :employment_hr_audit_valid,
             check:
               "action IN ('create','edit_contact','change_classification','assign_shop','end_shop') AND changed_fields <@ ARRAY['first_name','last_name','phone','email','home_address','classification','starts_on','ends_on']::varchar[] AND (employment_id IS NULL OR business_id IS NOT NULL) AND ((assignment_id IS NULL AND shop_id IS NULL) OR (assignment_id IS NOT NULL AND shop_id IS NOT NULL AND employment_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND employment_id IS NOT NULL AND ((action='create' AND reason='created' AND classification_history_id IS NOT NULL) OR (action='edit_contact' AND reason='updated' AND assignment_id IS NULL AND classification_history_id IS NULL) OR (action='change_classification' AND reason='reclassified' AND classification_history_id IS NOT NULL AND assignment_id IS NULL) OR (action='assign_shop' AND reason='assigned' AND assignment_id IS NOT NULL AND classification_history_id IS NULL) OR (action='end_shop' AND reason='ended' AND assignment_id IS NOT NULL AND classification_history_id IS NULL))) OR (outcome='denied' AND changed_fields='{}' AND classification_history_id IS NULL AND reason IN ('forbidden','invalid_input','employment_ended','outstanding_work','already_assigned','assignment_ended','unchanged','invalid_date','invalid_shop')))"
           )

    execute employment_guard(true)

    execute """
    CREATE FUNCTION magnum_record_employment_classification() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP='INSERT' OR NEW.classification IS DISTINCT FROM OLD.classification THEN
        INSERT INTO employment_classification_history(employment_id,business_id,previous_classification,classification,source,occurred_at)
        VALUES(NEW.id,NEW.business_id,CASE WHEN TG_OP='UPDATE' THEN OLD.classification ELSE NULL END,NEW.classification,CASE WHEN TG_OP='INSERT' THEN 'created' ELSE 'changed' END,NEW.updated_at);
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER employment_classification_recorder AFTER INSERT OR UPDATE ON employments FOR EACH ROW EXECUTE FUNCTION magnum_record_employment_classification()"

    execute """
    CREATE FUNCTION magnum_guard_hr_history() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'HR/classification history is immutable' USING ERRCODE='23514', CONSTRAINT='employment_hr_history_immutable';
    END $$
    """

    for table <- [:employment_classification_history, :employment_hr_audit_events] do
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION magnum_guard_hr_history()"
    end
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM employment_hr_audit_events) OR EXISTS(SELECT 1 FROM employment_classification_history WHERE source='changed') THEN RAISE EXCEPTION 'HR history requires a reviewed data-preserving rollback'; END IF; END $$"
    execute "DROP TRIGGER employment_classification_recorder ON employments"
    execute "DROP FUNCTION magnum_record_employment_classification()"
    execute employment_guard(false)

    for table <- [:employment_classification_history, :employment_hr_audit_events] do
      execute "DROP TRIGGER #{table}_immutable ON #{table}"
    end

    execute "DROP FUNCTION magnum_guard_hr_history()"
    drop table(:employment_hr_audit_events)
    drop table(:employment_classification_history)
  end

  defp employment_guard(hr?) do
    sql = """
    CREATE OR REPLACE FUNCTION magnum_guard_employment() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (NEW.business_id, NEW.classification, NEW.starts_on) IS DISTINCT FROM
           (OLD.business_id, OLD.classification, OLD.starts_on) OR
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
      RETURN NEW;
    END $$
    """

    if hr? do
      sql
      |> String.replace(
        "(NEW.business_id, NEW.classification, NEW.starts_on)",
        "(NEW.business_id, NEW.starts_on)"
      )
      |> String.replace(
        "(OLD.business_id, OLD.classification, OLD.starts_on)",
        "(OLD.business_id, OLD.starts_on)"
      )
      |> String.replace("  RETURN NEW;", """
          IF TG_OP='UPDATE' AND NEW.classification IS DISTINCT FROM OLD.classification AND (
            EXISTS(SELECT 1 FROM appointment_assignments WHERE employment_id=NEW.id AND status='active') OR
            EXISTS(SELECT 1 FROM work_shifts WHERE employment_id=NEW.id AND status='active' AND ends_at > timezone('UTC',statement_timestamp()))
          ) THEN
            RAISE EXCEPTION 'Classification change requires resolving outstanding work' USING ERRCODE='23514', CONSTRAINT='employments_outstanding_work';
          END IF;
          RETURN NEW;
      """)
    else
      sql
    end
  end
end
