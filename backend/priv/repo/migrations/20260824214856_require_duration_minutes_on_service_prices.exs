defmodule SchedulerApi.Repo.Migrations.RequireDurationMinutesOnServicePrices do
  use Ecto.Migration

  def change do
    alter table(:service_prices) do
      modify :duration_minutes, :integer, null: false
    end

    create constraint(
             :service_prices,
             :duration_minutes_must_be_positive,
             check: "duration_minutes > 0"
           )
  end
end
