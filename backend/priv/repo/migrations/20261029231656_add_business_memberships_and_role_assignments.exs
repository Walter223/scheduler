defmodule SchedulerApi.Repo.Migrations.AddBusinessMembershipsAndRoleAssignments do
  use Ecto.Migration

  def up do
    create table(:business_memberships) do
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :business_id, references(:businesses, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "active"
      add :revoked_at, :utc_datetime
      add :revoked_by_user_id, references(:users, on_delete: :restrict)
      add :revocation_reason, :string, size: 32
      timestamps(type: :utc_datetime)
    end

    create unique_index(:business_memberships, [:user_id, :business_id])
    create unique_index(:business_memberships, [:id, :business_id])
    create index(:business_memberships, [:business_id])

    create table(:role_assignments) do
      add :membership_id, :bigint, null: false
      add :business_id, :bigint, null: false
      add :shop_id, :bigint
      add :role, :string, null: false
      add :status, :string, null: false, default: "active"
      add :revoked_at, :utc_datetime
      add :revoked_by_user_id, references(:users, on_delete: :restrict)
      add :revocation_reason, :string, size: 32
      timestamps(type: :utc_datetime)
    end

    execute "ALTER TABLE role_assignments ADD CONSTRAINT role_assignments_membership_business_fkey FOREIGN KEY (membership_id, business_id) REFERENCES business_memberships(id, business_id) ON DELETE RESTRICT"

    execute "ALTER TABLE role_assignments ADD CONSTRAINT role_assignments_shop_business_fkey FOREIGN KEY (shop_id, business_id) REFERENCES shops(id, business_id) ON DELETE RESTRICT"

    create index(:role_assignments, [:business_id])
    create index(:role_assignments, [:shop_id, :business_id])
    # Two partial indexes handle NULL scope without requiring PG15 NULLS NOT DISTINCT.
    create unique_index(:role_assignments, [:membership_id, :role],
             name: :role_assignments_active_business_unique,
             where: "status = 'active' AND shop_id IS NULL"
           )

    create unique_index(:role_assignments, [:membership_id, :role, :shop_id],
             name: :role_assignments_active_shop_unique,
             where: "status = 'active' AND shop_id IS NOT NULL"
           )

    create constraint(:role_assignments, :role_assignments_role_scope,
             check:
               "(role IN ('business_owner', 'business_manager') AND shop_id IS NULL) OR (role IN ('shop_manager', 'employee') AND shop_id IS NOT NULL)"
           )

    for table <- [:business_memberships, :role_assignments] do
      create constraint(table, "#{table}_lifecycle",
               check:
                 "(status = 'active' AND revoked_at IS NULL AND revoked_by_user_id IS NULL AND revocation_reason IS NULL) OR (status = 'revoked' AND revoked_at IS NOT NULL AND revoked_at >= inserted_at AND revocation_reason IN ('manual', 'membership_revoked') AND revocation_reason IS NOT NULL)"
             )
    end

    execute """
    CREATE FUNCTION magnum_guard_membership_identity() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF (NEW.user_id, NEW.business_id) IS DISTINCT FROM (OLD.user_id, OLD.business_id) THEN
        RAISE EXCEPTION 'Membership identity is immutable' USING ERRCODE = '23514', CONSTRAINT = 'business_memberships_immutable';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER membership_identity_guard BEFORE UPDATE ON business_memberships FOR EACH ROW EXECUTE FUNCTION magnum_guard_membership_identity()"

    # Serialize grants against membership revocation, even for direct SQL writers.
    # Revoked grants are terminal history; restoration requires a NEW assignment.
    execute """
    CREATE FUNCTION magnum_guard_role_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF (NEW.membership_id, NEW.business_id, NEW.shop_id, NEW.role) IS DISTINCT FROM
           (OLD.membership_id, OLD.business_id, OLD.shop_id, OLD.role) OR
           (OLD.status = 'revoked' AND NEW IS DISTINCT FROM OLD) THEN
          RAISE EXCEPTION 'Role assignment identity and revoked history are immutable' USING ERRCODE = '23514', CONSTRAINT = 'role_assignments_immutable';
        END IF;
      END IF;
      IF NEW.status = 'active' THEN
        PERFORM 1 FROM business_memberships WHERE id = NEW.membership_id AND business_id = NEW.business_id AND status = 'active' FOR UPDATE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Active assignment requires active matching membership' USING ERRCODE = '23514', CONSTRAINT = 'role_assignments_active_membership';
        END IF;
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER role_assignment_guard BEFORE INSERT OR UPDATE ON role_assignments FOR EACH ROW EXECUTE FUNCTION magnum_guard_role_assignment()"

    execute """
    CREATE FUNCTION magnum_revoke_membership_roles() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'revoked' THEN
        UPDATE role_assignments SET status = 'revoked', revoked_at = NEW.revoked_at,
          revoked_by_user_id = NEW.revoked_by_user_id, revocation_reason = 'membership_revoked', updated_at = NEW.updated_at
        WHERE membership_id = NEW.id AND status = 'active';
      END IF;
      RETURN NEW;
    END $$
    """

    execute "CREATE TRIGGER membership_revoke_roles AFTER UPDATE OF status ON business_memberships FOR EACH ROW EXECUTE FUNCTION magnum_revoke_membership_roles()"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS membership_identity_guard ON business_memberships"
    execute "DROP FUNCTION IF EXISTS magnum_guard_membership_identity()"
    execute "DROP TRIGGER membership_revoke_roles ON business_memberships"
    execute "DROP FUNCTION magnum_revoke_membership_roles()"
    execute "DROP TRIGGER role_assignment_guard ON role_assignments"
    execute "DROP FUNCTION magnum_guard_role_assignment()"
    drop table(:role_assignments)
    drop table(:business_memberships)
  end
end
