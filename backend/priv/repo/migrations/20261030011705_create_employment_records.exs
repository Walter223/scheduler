defmodule SchedulerApi.Repo.Migrations.CreateEmploymentRecords do
  use Ecto.Migration

  def up do
    create table(:employments) do
      add :business_id, references(:businesses, on_delete: :restrict), null: false
      add :user_id, references(:users, on_delete: :restrict)
      add :first_name, :string, size: 100, null: false
      add :last_name, :string, size: 100, null: false
      add :classification, :string, size: 32, null: false
      add :status, :string, size: 16, null: false, default: "active"
      add :starts_on, :date, null: false
      add :ends_on, :date
      timestamps(type: :utc_datetime)
    end

    create unique_index(:employments, [:id, :business_id])
    create unique_index(:employments, [:business_id, :user_id], where: "user_id IS NOT NULL")
    create index(:employments, [:business_id, :status])
    create index(:employments, [:user_id])

    execute "ALTER TABLE employments ADD CONSTRAINT employments_user_business_fkey FOREIGN KEY (user_id, business_id) REFERENCES business_memberships(user_id, business_id) ON DELETE RESTRICT"

    create constraint(:employments, :employments_classification_valid,
             check:
               "classification IN ('detailer','shop_manager','business_manager','business_owner')"
           )

    create constraint(:employments, :employments_names_valid,
             check: "first_name ~ '[^[:space:]]' AND last_name ~ '[^[:space:]]'"
           )

    create constraint(:employments, :employments_lifecycle,
             check:
               "(status = 'active' AND ends_on IS NULL) OR (status = 'ended' AND ends_on IS NOT NULL AND ends_on >= starts_on)"
           )

    create table(:employment_shop_assignments) do
      add :employment_id, :bigint, null: false
      add :business_id, :bigint, null: false
      add :shop_id, :bigint, null: false
      add :status, :string, size: 16, null: false, default: "active"
      add :starts_on, :date, null: false
      add :ends_on, :date
      timestamps(type: :utc_datetime)
    end

    execute "ALTER TABLE employment_shop_assignments ADD CONSTRAINT employment_shop_assignments_employment_business_fkey FOREIGN KEY (employment_id, business_id) REFERENCES employments(id, business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE employment_shop_assignments ADD CONSTRAINT employment_shop_assignments_shop_business_fkey FOREIGN KEY (shop_id, business_id) REFERENCES shops(id, business_id) ON DELETE RESTRICT"

    create unique_index(:employment_shop_assignments, [:employment_id, :shop_id],
             name: :employment_shop_assignments_active_unique,
             where: "status = 'active'"
           )

    create index(:employment_shop_assignments, [:shop_id, :business_id, :status])
    create index(:employment_shop_assignments, [:employment_id, :business_id])

    create constraint(:employment_shop_assignments, :employment_shop_assignments_lifecycle,
             check:
               "(status = 'active' AND ends_on IS NULL) OR (status = 'ended' AND ends_on IS NOT NULL AND ends_on >= starts_on)"
           )

    execute """
    CREATE FUNCTION magnum_guard_employment() RETURNS trigger LANGUAGE plpgsql AS $$
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

    execute "CREATE TRIGGER employment_guard BEFORE INSERT OR UPDATE ON employments FOR EACH ROW EXECUTE FUNCTION magnum_guard_employment()"

    execute """
    CREATE FUNCTION magnum_guard_employment_shop_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE parent employments%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE' AND (
        (NEW.employment_id, NEW.business_id, NEW.shop_id, NEW.starts_on) IS DISTINCT FROM
        (OLD.employment_id, OLD.business_id, OLD.shop_id, OLD.starts_on) OR
        (OLD.status = 'ended' AND NEW IS DISTINCT FROM OLD)
      ) THEN
        RAISE EXCEPTION 'Assignment ownership and ended history are immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'employment_shop_assignments_immutable';
      END IF;
      IF TG_OP = 'INSERT' OR NEW.status = 'active' THEN
        -- Same parent lock as termination: no assignment may race past an end.
        SELECT * INTO parent FROM employments WHERE id = NEW.employment_id FOR UPDATE;
      ELSE
        -- Closing does not upgrade a parent lock after locking the child row.
        SELECT * INTO parent FROM employments WHERE id = NEW.employment_id;
      END IF;
      IF NOT FOUND THEN RETURN NEW; END IF; -- Composite FK supplies the error.
      IF (NEW.status = 'active' AND parent.status <> 'active') OR
         NEW.starts_on < parent.starts_on OR
         (parent.ends_on IS NOT NULL AND (NEW.ends_on IS NULL OR NEW.ends_on > parent.ends_on)) THEN
        RAISE EXCEPTION 'Assignment must fit the employment lifecycle and dates'
          USING ERRCODE = '23514', CONSTRAINT = 'employment_shop_assignments_employment_dates';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER employment_shop_assignment_guard BEFORE INSERT OR UPDATE ON employment_shop_assignments FOR EACH ROW EXECUTE FUNCTION magnum_guard_employment_shop_assignment()"
  end

  def down do
    execute "DROP TRIGGER employment_shop_assignment_guard ON employment_shop_assignments"
    execute "DROP FUNCTION magnum_guard_employment_shop_assignment()"
    execute "DROP TRIGGER employment_guard ON employments"
    execute "DROP FUNCTION magnum_guard_employment()"
    drop table(:employment_shop_assignments)
    drop table(:employments)
  end
end
