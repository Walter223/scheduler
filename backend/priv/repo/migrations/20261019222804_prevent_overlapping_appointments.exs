defmodule SchedulerApi.Repo.Migrations.PreventOverlappingAppointments do
  use Ecto.Migration

  def up do
    # UTC datetimes are stored as timestamp without time zone by Ecto.
    # No extension is needed: GiST natively supports timestamp ranges.
    execute """
    ALTER TABLE appointments
    ADD CONSTRAINT appointments_no_active_overlap
    EXCLUDE USING gist (
      tsrange(
        starts_at,
        starts_at + duration_minutes * interval '1 minute' + interval '30 minutes',
        '[)'
      ) WITH &&
    ) WHERE (status IN ('pending', 'confirmed'))
    """
  end

  def down do
    execute "ALTER TABLE appointments DROP CONSTRAINT appointments_no_active_overlap"
  end
end
