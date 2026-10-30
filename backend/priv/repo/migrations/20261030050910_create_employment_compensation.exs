defmodule SchedulerApi.Repo.Migrations.CreateEmploymentCompensation do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create table(:compensation_rates) do
      add :business_id, :bigint, null: false
      add :employment_id, :bigint, null: false
      add :pay_basis, :string, size: 16, null: false
      add :currency, :string, size: 3, null: false, default: "USD"
      # No typmod rounding: reject fractional cents rather than silently round.
      add :amount, :decimal, null: false
      add :effective_from, :date, null: false
      add :effective_until, :date
      timestamps(type: :utc_datetime, updated_at: false)
    end

    execute "ALTER TABLE compensation_rates ADD CONSTRAINT compensation_rates_employment_business_fkey FOREIGN KEY (employment_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    create unique_index(:compensation_rates, [:id, :employment_id, :business_id])
    create index(:compensation_rates, [:business_id, :employment_id, :effective_from])

    create constraint(:compensation_rates, :compensation_rates_money_valid,
             check:
               "currency = 'USD' AND pay_basis IN ('hourly','annual_salary') AND amount > 0 AND amount < 1000000000000 AND amount = trunc(amount,2)"
           )

    create constraint(:compensation_rates, :compensation_rates_dates_valid,
             check:
               "isfinite(effective_from) AND (effective_until IS NULL OR (isfinite(effective_until) AND effective_until > effective_from))"
           )

    execute "ALTER TABLE compensation_rates ADD CONSTRAINT compensation_rates_no_overlap EXCLUDE USING gist (employment_id WITH =, daterange(effective_from,effective_until,'[)') WITH &&)"

    create table(:compensation_audit_events) do
      add :actor_user_id, references(:users, on_delete: :restrict)
      add :business_id, :bigint
      add :employment_id, :bigint
      add :rate_id, :bigint
      add :closed_rate_id, :bigint
      add :closed_effective_until, :date
      add :action, :string, null: false, default: "set_rate"
      add :outcome, :string, null: false
      add :reason, :string, null: false
      add :occurred_at, :utc_datetime, null: false
    end

    execute "ALTER TABLE compensation_audit_events ADD CONSTRAINT compensation_audit_employment_business_fkey FOREIGN KEY (employment_id,business_id) REFERENCES employments(id,business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE compensation_audit_events ADD CONSTRAINT compensation_audit_rate_fkey FOREIGN KEY (rate_id,employment_id,business_id) REFERENCES compensation_rates(id,employment_id,business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE compensation_audit_events ADD CONSTRAINT compensation_audit_closed_rate_fkey FOREIGN KEY (closed_rate_id,employment_id,business_id) REFERENCES compensation_rates(id,employment_id,business_id) ON DELETE RESTRICT"

    create index(:compensation_audit_events, [:business_id, :employment_id, :occurred_at, :id])

    create constraint(:compensation_audit_events, :compensation_audit_valid,
             check:
               "action = 'set_rate' AND ((outcome = 'applied' AND reason = 'created' AND actor_user_id IS NOT NULL AND business_id IS NOT NULL AND employment_id IS NOT NULL AND rate_id IS NOT NULL) OR (outcome = 'denied' AND reason IN ('forbidden','invalid_input','employment_ended','invalid_effective_date','effective_date_conflict') AND rate_id IS NULL AND closed_rate_id IS NULL AND closed_effective_until IS NULL)) AND ((closed_rate_id IS NULL AND closed_effective_until IS NULL) OR (closed_rate_id IS NOT NULL AND closed_effective_until IS NOT NULL)) AND ((employment_id IS NULL AND business_id IS NULL) OR (employment_id IS NOT NULL AND business_id IS NOT NULL))"
           )

    execute """
    CREATE FUNCTION magnum_guard_compensation_rate() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE parent employments%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (NEW.id,NEW.business_id,NEW.employment_id,NEW.pay_basis,NEW.currency,NEW.amount,NEW.effective_from,NEW.inserted_at) IS DISTINCT FROM
           (OLD.id,OLD.business_id,OLD.employment_id,OLD.pay_basis,OLD.currency,OLD.amount,OLD.effective_from,OLD.inserted_at) OR
           OLD.effective_until IS NOT NULL OR NEW.effective_until IS NULL THEN
          RAISE EXCEPTION 'Rates are immutable except one audited period closure'
            USING ERRCODE='23514', CONSTRAINT='compensation_rates_immutable';
        END IF;
      ELSE
        SELECT * INTO parent FROM employments WHERE id=NEW.employment_id FOR UPDATE;
        IF FOUND AND (parent.status <> 'active' OR NEW.effective_from < parent.starts_on) THEN
          RAISE EXCEPTION 'New compensation requires active employment and valid start'
            USING ERRCODE='23514', CONSTRAINT='compensation_rates_employment_valid';
        END IF;
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER compensation_rate_guard BEFORE INSERT OR UPDATE ON compensation_rates FOR EACH ROW EXECUTE FUNCTION magnum_guard_compensation_rate()"

    execute """
    CREATE FUNCTION magnum_guard_compensation_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'Compensation audit events are immutable' USING ERRCODE='23514', CONSTRAINT='compensation_audit_immutable';
    END $$
    """

    execute "CREATE TRIGGER compensation_audit_guard BEFORE UPDATE ON compensation_audit_events FOR EACH ROW EXECUTE FUNCTION magnum_guard_compensation_audit()"
  end

  def down do
    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM compensation_rates) OR EXISTS (SELECT 1 FROM compensation_audit_events) THEN
        RAISE EXCEPTION 'Compensation history requires a reviewed data-preserving rollback';
      END IF;
    END $$
    """

    execute "DROP TRIGGER compensation_audit_guard ON compensation_audit_events"
    execute "DROP FUNCTION magnum_guard_compensation_audit()"
    execute "DROP TRIGGER compensation_rate_guard ON compensation_rates"
    execute "DROP FUNCTION magnum_guard_compensation_rate()"
    drop table(:compensation_audit_events)
    drop table(:compensation_rates)
  end
end
