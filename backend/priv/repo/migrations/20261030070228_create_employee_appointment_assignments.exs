defmodule SchedulerApi.Repo.Migrations.CreateEmployeeAppointmentAssignments do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE work_shift_audit_events DROP CONSTRAINT work_shift_audit_valid"

    create constraint(:work_shift_audit_events, :work_shift_audit_valid,
             check: shift_audit_check(true)
           )

    create unique_index(:appointments, [:id, :business_id, :shop_id],
             name: :appointments_job_identity
           )

    create table(:appointment_assignments) do
      add :appointment_id, :bigint, null: false
      add :assignment_id, :bigint, null: false
      add :employment_id, :bigint, null: false
      add :business_id, :bigint, null: false
      add :shop_id, :bigint, null: false
      add :work_shift_id, :bigint, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "active"
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime, updated_at: false)
    end

    execute "ALTER TABLE appointment_assignments ADD CONSTRAINT appointment_jobs_appointment_fkey FOREIGN KEY (appointment_id,business_id,shop_id) REFERENCES appointments(id,business_id,shop_id) ON DELETE RESTRICT"

    execute "ALTER TABLE appointment_assignments ADD CONSTRAINT appointment_jobs_assignment_fkey FOREIGN KEY (assignment_id,employment_id,business_id,shop_id) REFERENCES employment_shop_assignments(id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    execute "ALTER TABLE appointment_assignments ADD CONSTRAINT appointment_jobs_shift_fkey FOREIGN KEY (work_shift_id,assignment_id,employment_id,business_id,shop_id) REFERENCES work_shifts(id,assignment_id,employment_id,business_id,shop_id) ON DELETE RESTRICT"

    create unique_index(:appointment_assignments, [:appointment_id],
             where: "status='active'",
             name: :appointment_jobs_one_active
           )

    create unique_index(:appointment_assignments, [:id, :appointment_id, :business_id, :shop_id],
             name: :appointment_jobs_audit_identity
           )

    create index(:appointment_assignments, [:shop_id, :starts_at, :id])
    create index(:appointment_assignments, [:employment_id, :starts_at])
    create index(:appointment_assignments, [:work_shift_id], where: "status='active'")

    create constraint(:appointment_assignments, :appointment_jobs_lifecycle,
             check:
               "(status='active' AND closed_at IS NULL) OR (status IN ('reassigned','unassigned') AND closed_at IS NOT NULL AND closed_at >= inserted_at)"
           )

    create constraint(:appointment_assignments, :appointment_jobs_period,
             check: "isfinite(starts_at) AND isfinite(ends_at) AND starts_at < ends_at"
           )

    execute "ALTER TABLE appointment_assignments ADD CONSTRAINT appointment_jobs_no_overlap EXCLUDE USING gist (business_id WITH =, employment_id WITH =, tsrange(starts_at,ends_at,'[)') WITH &&) WHERE (status='active')"

    create table(:appointment_assignment_audit_events) do
      add :actor_user_id, references(:users, on_delete: :restrict)
      add :appointment_id, :bigint
      add :business_id, :bigint
      add :shop_id, :bigint
      add :job_id, :bigint
      add :replacement_job_id, :bigint
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string, size: 40, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT appointment_job_audit_appointment_fkey FOREIGN KEY (appointment_id,business_id,shop_id) REFERENCES appointments(id,business_id,shop_id) ON DELETE RESTRICT"

    for field <- ["job_id", "replacement_job_id"] do
      execute "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT appointment_job_audit_#{field}_fkey FOREIGN KEY (#{field},appointment_id,business_id,shop_id) REFERENCES appointment_assignments(id,appointment_id,business_id,shop_id) ON DELETE RESTRICT"
    end

    create index(:appointment_assignment_audit_events, [:business_id, :shop_id, :occurred_at, :id])

    create constraint(:appointment_assignment_audit_events, :appointment_job_audit_valid,
             check:
               "action IN ('assign','reassign','unassign') AND reason IN ('assigned','reassigned','unassigned','forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment') AND ((appointment_id IS NULL AND business_id IS NULL AND shop_id IS NULL AND job_id IS NULL AND replacement_job_id IS NULL) OR (appointment_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND job_id IS NOT NULL AND ((action='assign' AND reason='assigned' AND replacement_job_id IS NULL) OR (action='unassign' AND reason='unassigned' AND replacement_job_id IS NULL) OR (action='reassign' AND reason='reassigned' AND replacement_job_id IS NOT NULL))) OR (outcome='denied' AND replacement_job_id IS NULL AND reason IN ('forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment')))"
           )

    execute """
    CREATE FUNCTION magnum_guard_appointment_job() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE worker employments%ROWTYPE; assigned employment_shop_assignments%ROWTYPE;
    location shops%ROWTYPE; shift work_shifts%ROWTYPE; booking appointments%ROWTYPE;
    first_day date; last_day date;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF (NEW.id,NEW.appointment_id,NEW.assignment_id,NEW.employment_id,NEW.business_id,NEW.shop_id,NEW.work_shift_id,NEW.starts_at,NEW.ends_at,NEW.inserted_at) IS DISTINCT FROM
           (OLD.id,OLD.appointment_id,OLD.assignment_id,OLD.employment_id,OLD.business_id,OLD.shop_id,OLD.work_shift_id,OLD.starts_at,OLD.ends_at,OLD.inserted_at) OR
           OLD.status <> 'active' OR NEW.status NOT IN ('reassigned','unassigned') THEN
          RAISE EXCEPTION 'Job history is immutable' USING ERRCODE='23514', CONSTRAINT='appointment_jobs_immutable';
        END IF;
        RETURN NEW;
      END IF;
      -- Same parent-first order as work shifts; no child-to-parent lock upgrades.
      SELECT * INTO worker FROM employments WHERE id=NEW.employment_id FOR UPDATE;
      SELECT * INTO assigned FROM employment_shop_assignments WHERE id=NEW.assignment_id FOR SHARE;
      SELECT * INTO location FROM shops WHERE id=NEW.shop_id FOR SHARE;
      SELECT * INTO shift FROM work_shifts WHERE id=NEW.work_shift_id FOR SHARE;
      SELECT * INTO booking FROM appointments WHERE id=NEW.appointment_id FOR SHARE;
      IF worker.id IS NULL OR assigned.id IS NULL OR location.id IS NULL OR shift.id IS NULL OR booking.id IS NULL THEN
        RAISE EXCEPTION 'Missing persisted job relationships' USING ERRCODE='23503', CONSTRAINT='appointment_jobs_assignment_fkey';
      END IF;
      first_day := (NEW.starts_at AT TIME ZONE 'UTC' AT TIME ZONE location.timezone)::date;
      last_day := ((NEW.ends_at - interval '1 microsecond') AT TIME ZONE 'UTC' AT TIME ZONE location.timezone)::date;
      IF worker.status <> 'active' OR worker.classification <> 'detailer' OR assigned.status <> 'active' OR location.status <> 'active' OR
         NOT EXISTS (SELECT 1 FROM businesses WHERE id=NEW.business_id AND status='active') OR
         first_day < worker.starts_on OR first_day < assigned.starts_on OR
         (worker.ends_on IS NOT NULL AND last_day > worker.ends_on) OR (assigned.ends_on IS NOT NULL AND last_day > assigned.ends_on) THEN
        RAISE EXCEPTION 'Job requires an effective active Detailer assignment' USING ERRCODE='23514', CONSTRAINT='appointment_jobs_eligible';
      END IF;
      IF NEW.status <> 'active' OR NEW.closed_at IS NOT NULL OR booking.status NOT IN ('pending','confirmed') OR
         NEW.starts_at IS DISTINCT FROM booking.starts_at OR NEW.ends_at IS DISTINCT FROM booking.starts_at + (booking.duration_minutes+30)*interval '1 minute' THEN
        RAISE EXCEPTION 'Job must snapshot active appointment occupied period' USING ERRCODE='23514', CONSTRAINT='appointment_jobs_snapshot';
      END IF;
      IF shift.status <> 'active' OR shift.starts_at > NEW.starts_at OR shift.ends_at < NEW.ends_at THEN
        RAISE EXCEPTION 'Job requires one covering active shift, including buffer' USING ERRCODE='23514', CONSTRAINT='appointment_jobs_shift_coverage';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER appointment_job_guard BEFORE INSERT OR UPDATE ON appointment_assignments FOR EACH ROW EXECUTE FUNCTION magnum_guard_appointment_job()"

    execute """
    CREATE FUNCTION magnum_protect_assigned_job_source() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_TABLE_NAME='work_shifts' THEN
        IF NEW.status IS DISTINCT FROM OLD.status AND EXISTS (SELECT 1 FROM appointment_assignments WHERE work_shift_id=OLD.id AND status='active') THEN
          RAISE EXCEPTION 'Unassign jobs before changing their covering shift' USING ERRCODE='23514', CONSTRAINT='work_shifts_active_jobs';
        END IF;
      ELSE
        IF (NEW.starts_at,NEW.duration_minutes,NEW.business_id,NEW.shop_id) IS DISTINCT FROM (OLD.starts_at,OLD.duration_minutes,OLD.business_id,OLD.shop_id) OR
           (NEW.status NOT IN ('pending','confirmed') AND NEW.status IS DISTINCT FROM OLD.status) THEN
          IF EXISTS (SELECT 1 FROM appointment_assignments WHERE appointment_id=OLD.id AND status='active') THEN
            RAISE EXCEPTION 'Unassign jobs before changing appointment scheduling' USING ERRCODE='23514', CONSTRAINT='appointments_active_jobs';
          END IF;
        END IF;
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER work_shift_job_guard BEFORE UPDATE ON work_shifts FOR EACH ROW EXECUTE FUNCTION magnum_protect_assigned_job_source()"

    execute "CREATE TRIGGER appointment_job_source_guard BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION magnum_protect_assigned_job_source()"

    execute """
    CREATE FUNCTION magnum_guard_appointment_job_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'Job audit history is immutable' USING ERRCODE='23514', CONSTRAINT='appointment_job_audit_immutable';
    END $$
    """

    execute "CREATE TRIGGER appointment_job_audit_guard BEFORE UPDATE ON appointment_assignment_audit_events FOR EACH ROW EXECUTE FUNCTION magnum_guard_appointment_job_audit()"
  end

  def down do
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM appointment_assignments) OR EXISTS(SELECT 1 FROM appointment_assignment_audit_events) THEN RAISE EXCEPTION 'Job history requires a reviewed data-preserving rollback'; END IF; END $$"

    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM work_shift_audit_events WHERE reason='assigned_jobs') THEN RAISE EXCEPTION 'Shift denial history requires a reviewed rollback'; END IF; END $$"
    execute "ALTER TABLE work_shift_audit_events DROP CONSTRAINT work_shift_audit_valid"

    create constraint(:work_shift_audit_events, :work_shift_audit_valid,
             check: shift_audit_check(false)
           )

    execute "DROP TRIGGER appointment_job_audit_guard ON appointment_assignment_audit_events"
    execute "DROP FUNCTION magnum_guard_appointment_job_audit()"
    execute "DROP TRIGGER appointment_job_source_guard ON appointments"
    execute "DROP TRIGGER work_shift_job_guard ON work_shifts"
    execute "DROP FUNCTION magnum_protect_assigned_job_source()"
    execute "DROP TRIGGER appointment_job_guard ON appointment_assignments"
    execute "DROP FUNCTION magnum_guard_appointment_job()"
    drop table(:appointment_assignment_audit_events)
    drop table(:appointment_assignments)
    drop index(:appointments, [:id, :business_id, :shop_id], name: :appointments_job_identity)
  end

  # Preserve the existing exact audit contract while adding one bounded denial.
  defp shift_audit_check(include_jobs?) do
    check =
      "action IN ('create','cancel','reschedule') AND reason IN ('created','cancelled','rescheduled','forbidden','invalid_input','ineligible_assignment','overlap','not_active','unchanged') AND ((assignment_id IS NULL AND employment_id IS NULL AND business_id IS NULL AND shop_id IS NULL AND shift_id IS NULL AND replacement_shift_id IS NULL) OR (assignment_id IS NOT NULL AND employment_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND shift_id IS NOT NULL AND ((action='create' AND reason='created' AND replacement_shift_id IS NULL) OR (action='cancel' AND reason='cancelled' AND replacement_shift_id IS NULL) OR (action='reschedule' AND reason='rescheduled' AND replacement_shift_id IS NOT NULL))) OR (outcome='denied' AND replacement_shift_id IS NULL AND reason IN ('forbidden','invalid_input','ineligible_assignment','overlap','not_active','unchanged')))"

    if include_jobs?,
      do: String.replace(check, "'unchanged'", "'unchanged','assigned_jobs'"),
      else: check
  end
end
