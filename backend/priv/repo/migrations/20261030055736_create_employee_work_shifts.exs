defmodule SchedulerApi.Repo.Migrations.CreateEmployeeWorkShifts do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create unique_index(
             :employment_shop_assignments,
             [:id, :employment_id, :business_id, :shop_id],
             name: :employment_assignment_shift_identity
           )

    create table(:work_shifts) do
      add :assignment_id, :bigint, null: false
      add :employment_id, :bigint, null: false
      add :business_id, :bigint, null: false
      add :shop_id, :bigint, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :timezone, :string, null: false
      add :status, :string, size: 16, null: false, default: "active"
      add :supersedes_id, :bigint
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(
             :work_shifts,
             [:id, :assignment_id, :employment_id, :business_id, :shop_id],
             name: :work_shifts_audit_identity
           )

    create unique_index(:work_shifts, [:supersedes_id], where: "supersedes_id IS NOT NULL")
    create index(:work_shifts, [:shop_id, :starts_at, :id])
    create index(:work_shifts, [:business_id, :employment_id, :starts_at])

    execute "ALTER TABLE work_shifts ADD CONSTRAINT work_shifts_assignment_fkey FOREIGN KEY (assignment_id,employment_id,business_id,shop_id) REFERENCES employment_shop_assignments(id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    execute "ALTER TABLE work_shifts ADD CONSTRAINT work_shifts_supersedes_fkey FOREIGN KEY (supersedes_id,assignment_id,employment_id,business_id,shop_id) REFERENCES work_shifts(id,assignment_id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    create constraint(:work_shifts, :work_shifts_period_valid,
             check: "isfinite(starts_at) AND isfinite(ends_at) AND starts_at < ends_at"
           )

    create constraint(:work_shifts, :work_shifts_lifecycle,
             check:
               "(status='active' AND closed_at IS NULL) OR (status IN ('cancelled','superseded') AND closed_at IS NOT NULL AND closed_at >= inserted_at)"
           )

    execute "ALTER TABLE work_shifts ADD CONSTRAINT work_shifts_no_active_overlap EXCLUDE USING gist (business_id WITH =, employment_id WITH =, tsrange(starts_at,ends_at,'[)') WITH &&) WHERE (status='active')"

    create table(:work_shift_audit_events) do
      add :actor_user_id, references(:users, on_delete: :restrict)
      add :business_id, :bigint
      add :employment_id, :bigint
      add :shop_id, :bigint
      add :assignment_id, :bigint
      add :shift_id, :bigint
      add :replacement_shift_id, :bigint
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE work_shift_audit_events ADD CONSTRAINT work_shift_audit_assignment_fkey FOREIGN KEY (assignment_id,employment_id,business_id,shop_id) REFERENCES employment_shop_assignments(id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    for {field, name} <- [
          {"shift_id", "work_shift_audit_shift_fkey"},
          {"replacement_shift_id", "work_shift_audit_replacement_fkey"}
        ] do
      execute "ALTER TABLE work_shift_audit_events ADD CONSTRAINT #{name} FOREIGN KEY (#{field},assignment_id,employment_id,business_id,shop_id) REFERENCES work_shifts(id,assignment_id,employment_id,business_id,shop_id) ON DELETE RESTRICT"
    end

    create index(:work_shift_audit_events, [:business_id, :shop_id, :occurred_at, :id])

    create constraint(:work_shift_audit_events, :work_shift_audit_valid,
             check:
               "action IN ('create','cancel','reschedule') AND reason IN ('created','cancelled','rescheduled','forbidden','invalid_input','ineligible_assignment','overlap','not_active','unchanged') AND ((assignment_id IS NULL AND employment_id IS NULL AND business_id IS NULL AND shop_id IS NULL AND shift_id IS NULL AND replacement_shift_id IS NULL) OR (assignment_id IS NOT NULL AND employment_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND shift_id IS NOT NULL AND ((action='create' AND reason='created' AND replacement_shift_id IS NULL) OR (action='cancel' AND reason='cancelled' AND replacement_shift_id IS NULL) OR (action='reschedule' AND reason='rescheduled' AND replacement_shift_id IS NOT NULL))) OR (outcome='denied' AND replacement_shift_id IS NULL AND reason IN ('forbidden','invalid_input','ineligible_assignment','overlap','not_active','unchanged')))"
           )

    execute """
    CREATE FUNCTION magnum_guard_work_shift() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE parent employments%ROWTYPE; assigned employment_shop_assignments%ROWTYPE; location shops%ROWTYPE;
    first_day date; last_day date;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF (NEW.id,NEW.assignment_id,NEW.employment_id,NEW.business_id,NEW.shop_id,NEW.starts_at,NEW.ends_at,NEW.timezone,NEW.supersedes_id,NEW.inserted_at) IS DISTINCT FROM
           (OLD.id,OLD.assignment_id,OLD.employment_id,OLD.business_id,OLD.shop_id,OLD.starts_at,OLD.ends_at,OLD.timezone,OLD.supersedes_id,OLD.inserted_at) OR
           OLD.status <> 'active' OR NEW.status NOT IN ('cancelled','superseded') THEN
          RAISE EXCEPTION 'Shift history is immutable; supersede or cancel active records'
            USING ERRCODE='23514', CONSTRAINT='work_shifts_immutable';
        END IF;
        RETURN NEW; -- Never upgrade a parent lock after locking a child row.
      END IF;
      IF NEW.status <> 'active' OR NEW.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Shifts start active' USING ERRCODE='23514', CONSTRAINT='work_shifts_lifecycle';
      END IF;
      SELECT * INTO parent FROM employments WHERE id=NEW.employment_id FOR UPDATE;
      IF NOT FOUND THEN RETURN NEW; END IF;
      SELECT * INTO assigned FROM employment_shop_assignments WHERE id=NEW.assignment_id FOR SHARE;
      IF NOT FOUND THEN RETURN NEW; END IF;
      SELECT * INTO location FROM shops WHERE id=NEW.shop_id FOR SHARE;
      IF NOT FOUND THEN RETURN NEW; END IF;
      IF NEW.timezone IS DISTINCT FROM location.timezone OR NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name=location.timezone) THEN
        RAISE EXCEPTION 'Use the persisted shop timezone' USING ERRCODE='23514', CONSTRAINT='work_shifts_timezone_valid';
      END IF;
      first_day := (NEW.starts_at AT TIME ZONE 'UTC' AT TIME ZONE location.timezone)::date;
      last_day := ((NEW.ends_at - interval '1 microsecond') AT TIME ZONE 'UTC' AT TIME ZONE location.timezone)::date;
      IF parent.status <> 'active' OR assigned.status <> 'active' OR location.status <> 'active' OR
         first_day < parent.starts_on OR first_day < assigned.starts_on OR
         (parent.ends_on IS NOT NULL AND last_day > parent.ends_on) OR
         (assigned.ends_on IS NOT NULL AND last_day > assigned.ends_on) THEN
        RAISE EXCEPTION 'Shift requires active employment and an effective shop assignment'
          USING ERRCODE='23514', CONSTRAINT='work_shifts_assignment_eligible';
      END IF;
      IF NEW.supersedes_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM work_shifts WHERE id=NEW.supersedes_id AND status='superseded') THEN
        RAISE EXCEPTION 'Replacement requires a superseded shift' USING ERRCODE='23514', CONSTRAINT='work_shifts_replacement_valid';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER work_shift_guard BEFORE INSERT OR UPDATE ON work_shifts FOR EACH ROW EXECUTE FUNCTION magnum_guard_work_shift()"

    execute """
    CREATE FUNCTION magnum_guard_work_shift_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'Work shift audit history is immutable' USING ERRCODE='23514', CONSTRAINT='work_shift_audit_immutable';
    END $$
    """

    execute "CREATE TRIGGER work_shift_audit_guard BEFORE UPDATE ON work_shift_audit_events FOR EACH ROW EXECUTE FUNCTION magnum_guard_work_shift_audit()"
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS (SELECT 1 FROM work_shifts) OR EXISTS (SELECT 1 FROM work_shift_audit_events) THEN RAISE EXCEPTION 'Work shift history requires a reviewed data-preserving rollback'; END IF; END $$"
    execute "DROP TRIGGER work_shift_audit_guard ON work_shift_audit_events"
    execute "DROP FUNCTION magnum_guard_work_shift_audit()"
    execute "DROP TRIGGER work_shift_guard ON work_shifts"
    execute "DROP FUNCTION magnum_guard_work_shift()"
    drop table(:work_shift_audit_events)
    drop table(:work_shifts)

    drop index(:employment_shop_assignments, [:id, :employment_id, :business_id, :shop_id],
           name: :employment_assignment_shift_identity
         )
  end
end
