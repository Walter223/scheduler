defmodule SchedulerApi.Repo.Migrations.CreateAppointments do
  use Ecto.Migration

  def change do
    create table(:appointments) do
      add :service_price_id,
          references(:service_prices, on_delete: :restrict),
          null: false

      add :starts_at, :utc_datetime, null: false
      add :duration_minutes, :integer, null: false
      add :price_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
