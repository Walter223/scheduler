defmodule SchedulerApi.Repo.Migrations.SupportAppointmentDetailerTeams do
  use Ecto.Migration

  def up do
    alter table(:appointment_assignments) do
      add :is_lead, :boolean, null: false, default: false
    end

    # Install employee uniqueness before lifting the old crew-size restriction.
    create unique_index(:appointment_assignments, [:appointment_id, :employment_id],
             where: "status='active'",
             name: :appointment_jobs_active_employee
           )

    drop index(:appointment_assignments, [:appointment_id], name: :appointment_jobs_one_active)

    create unique_index(:appointment_assignments, [:appointment_id],
             where: "status='active' AND is_lead",
             name: :appointment_jobs_one_lead
           )

    create constraint(:appointment_assignments, :appointment_jobs_lead_active,
             check: "NOT is_lead OR status='active'"
           )

    alter table(:appointment_assignment_audit_events) do
      add :previous_lead_job_id, :bigint
      add :lead_job_id, :bigint
    end

    for field <- ["previous_lead_job_id", "lead_job_id"] do
      execute "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT appointment_job_audit_#{field}_fkey FOREIGN KEY (#{field},appointment_id,business_id,shop_id) REFERENCES appointment_assignments(id,appointment_id,business_id,shop_id) ON DELETE RESTRICT"
    end

    execute "ALTER TABLE appointment_assignment_audit_events DROP CONSTRAINT appointment_job_audit_valid"

    create constraint(:appointment_assignment_audit_events, :appointment_job_audit_valid,
             check:
               "action IN ('assign','reassign','unassign','add_member','remove_member','designate_lead','clear_lead') AND reason IN ('assigned','reassigned','unassigned','forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment','ambiguous_team','lead_designated','lead_cleared','already_lead','no_lead') AND ((appointment_id IS NULL AND business_id IS NULL AND shop_id IS NULL AND job_id IS NULL AND replacement_job_id IS NULL AND previous_lead_job_id IS NULL AND lead_job_id IS NULL) OR (appointment_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND job_id IS NOT NULL AND ((action IN ('assign','add_member') AND reason='assigned' AND replacement_job_id IS NULL) OR (action IN ('unassign','remove_member') AND reason='unassigned' AND replacement_job_id IS NULL) OR (action='reassign' AND reason='reassigned' AND replacement_job_id IS NOT NULL) OR (action='designate_lead' AND reason='lead_designated' AND lead_job_id IS NOT NULL) OR (action='clear_lead' AND reason='lead_cleared' AND previous_lead_job_id IS NOT NULL AND lead_job_id IS NULL))) OR (outcome='denied' AND replacement_job_id IS NULL AND previous_lead_job_id IS NULL AND lead_job_id IS NULL AND reason IN ('forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment','ambiguous_team','already_lead','no_lead')))"
           )

    execute job_guard(true)
  end

  def down do
    # Never erase new team/lead history to manufacture single-assignee compatibility.
    execute "DO $$ BEGIN IF EXISTS(SELECT 1 FROM appointment_assignments WHERE is_lead) OR EXISTS(SELECT 1 FROM appointment_assignments WHERE status='active' GROUP BY appointment_id HAVING count(*)>1) OR EXISTS(SELECT 1 FROM appointment_assignment_audit_events WHERE action NOT IN ('assign','reassign','unassign') OR reason='ambiguous_team' OR previous_lead_job_id IS NOT NULL OR lead_job_id IS NOT NULL) THEN RAISE EXCEPTION 'Team history requires a reviewed data-preserving rollback'; END IF; END $$"

    create unique_index(:appointment_assignments, [:appointment_id],
             where: "status='active'",
             name: :appointment_jobs_one_active
           )

    execute "ALTER TABLE appointment_assignment_audit_events DROP CONSTRAINT appointment_job_audit_valid"

    create constraint(:appointment_assignment_audit_events, :appointment_job_audit_valid,
             check:
               "action IN ('assign','reassign','unassign') AND reason IN ('assigned','reassigned','unassigned','forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment') AND ((appointment_id IS NULL AND business_id IS NULL AND shop_id IS NULL AND job_id IS NULL AND replacement_job_id IS NULL) OR (appointment_id IS NOT NULL AND business_id IS NOT NULL AND shop_id IS NOT NULL)) AND ((outcome='applied' AND actor_user_id IS NOT NULL AND job_id IS NOT NULL AND ((action='assign' AND reason='assigned' AND replacement_job_id IS NULL) OR (action='unassign' AND reason='unassigned' AND replacement_job_id IS NULL) OR (action='reassign' AND reason='reassigned' AND replacement_job_id IS NOT NULL))) OR (outcome='denied' AND replacement_job_id IS NULL AND reason IN ('forbidden','ineligible_detailer','missing_covering_shift','overlap','already_assigned','not_assigned','unchanged','invalid_appointment')))"
           )

    for field <- ["previous_lead_job_id", "lead_job_id"] do
      execute "ALTER TABLE appointment_assignment_audit_events DROP CONSTRAINT appointment_job_audit_#{field}_fkey"
    end

    alter table(:appointment_assignment_audit_events) do
      remove :previous_lead_job_id
      remove :lead_job_id
    end

    execute job_guard(false)
    drop constraint(:appointment_assignments, :appointment_jobs_lead_active)
    drop index(:appointment_assignments, [:appointment_id], name: :appointment_jobs_one_lead)

    drop index(:appointment_assignments, [:appointment_id, :employment_id],
           name: :appointment_jobs_active_employee
         )

    alter table(:appointment_assignments) do
      remove :is_lead
    end
  end

  defp job_guard(teams?) do
    sql = """
    CREATE OR REPLACE FUNCTION magnum_guard_appointment_job() RETURNS trigger LANGUAGE plpgsql AS $$
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

    if teams?,
      do:
        String.replace(
          sql,
          "OLD.status <> 'active' OR NEW.status NOT IN ('reassigned','unassigned') THEN",
          "OLD.status <> 'active' OR NOT ((NEW.status IN ('reassigned','unassigned') AND NEW.is_lead=false) OR (NEW.status='active' AND NEW.is_lead IS DISTINCT FROM OLD.is_lead)) THEN"
        ),
      else: sql
  end
end
