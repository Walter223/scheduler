defmodule SchedulerApi.Repo.Migrations.AddDurationMinutesToServicePrices do
  use Ecto.Migration

  def change do
    alter table(:service_prices) do
      add :duration_minutes, :integer
    end
  end
end
