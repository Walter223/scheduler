defmodule SchedulerApi.Repo.Migrations.CompleteAppointmentsFoundation do
  use Ecto.Migration

  def change do
    alter table(:appointments) do
      add :customer_name, :string, null: false
      add :customer_email, :string, null: false
      add :customer_phone, :string, null: false
      add :vehicle_make, :string, null: false
      add :vehicle_model, :string, null: false
      add :notes, :text
      add :status, :string, null: false, default: "pending"
    end

    create index(:appointments, [:service_price_id])
    create index(:appointments, [:starts_at])
    create index(:appointments, [:status, :starts_at])

    create constraint(:appointments, :appointments_duration_positive,
             check: "duration_minutes > 0"
           )

    create constraint(:appointments, :appointments_price_positive, check: "price_cents > 0")

    create constraint(:appointments, :appointments_status_valid,
             check: "status IN ('pending', 'confirmed', 'completed', 'cancelled')"
           )

    for field <- [:customer_name, :customer_email, :customer_phone, :vehicle_make, :vehicle_model] do
      create constraint(:appointments, "appointments_#{field}_not_blank",
               check: "length(trim(#{field})) > 0"
             )
    end
  end
end
