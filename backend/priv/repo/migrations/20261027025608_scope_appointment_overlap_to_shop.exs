defmodule SchedulerApi.Repo.Migrations.ScopeAppointmentOverlapToShop do
  use Ecto.Migration

  def up do
    Enum.each(statements(), &execute/1)
  end

  @doc false
  def statements do
    # Add the replacement before dropping the old constraint, in one transaction.
    # Drain writers so old/new advisory-key schemes do not run concurrently.
    [
      "CREATE EXTENSION IF NOT EXISTS btree_gist",
      "LOCK TABLE appointments IN ACCESS EXCLUSIVE MODE",
      scoped_constraint_sql(),
      "ALTER TABLE appointments DROP CONSTRAINT appointments_no_active_overlap",
      "ALTER TABLE appointments RENAME CONSTRAINT appointments_no_shop_overlap TO appointments_no_active_overlap"
    ]
  end

  def down do
    execute "LOCK TABLE appointments IN ACCESS EXCLUSIVE MODE"
    # This intentionally fails safely if valid cross-shop overlaps now exist.
    # Review those bookings before attempting a return to global scheduling.
    execute """
    ALTER TABLE appointments ADD CONSTRAINT appointments_global_overlap_restore
    EXCLUDE USING gist (
      tsrange(starts_at, starts_at + duration_minutes * interval '1 minute' + interval '30 minutes', '[)') WITH &&
    ) WHERE (status IN ('pending', 'confirmed'))
    """

    execute "ALTER TABLE appointments DROP CONSTRAINT appointments_no_active_overlap"

    execute "ALTER TABLE appointments RENAME CONSTRAINT appointments_global_overlap_restore TO appointments_no_active_overlap"
  end

  @doc false
  def scoped_constraint_sql do
    """
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_shop_overlap
    EXCLUDE USING gist (
      shop_id WITH =,
      tsrange(starts_at, starts_at + duration_minutes * interval '1 minute' + interval '30 minutes', '[)') WITH &&
    ) WHERE (status IN ('pending', 'confirmed'))
    """
  end
end
