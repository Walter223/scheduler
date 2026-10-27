defmodule SchedulerApi.Repo.Migrations.SeparateAppointmentCustomerNames do
  use Ecto.Migration

  def up do
    # Required fields intentionally have no defaults or guessed legacy values.
    # Existing appointments must be explicitly cleared before this migration.
    alter table(:appointments) do
      add :customer_first_name, :string, size: 100, null: false
      add :customer_last_name, :string, size: 100, null: false
    end

    for field <- [:customer_first_name, :customer_last_name] do
      create constraint(:appointments, "appointments_#{field}_not_blank",
               check: "#{field} ~ '[^[:space:]]'"
             )
    end

    drop constraint(:appointments, :appointments_customer_name_not_blank)

    alter table(:appointments) do
      remove :customer_name
    end
  end

  def down do
    raise Ecto.MigrationError,
          "Separate customer names cannot restore discarded legacy name data; restore a backup instead"
  end
end
