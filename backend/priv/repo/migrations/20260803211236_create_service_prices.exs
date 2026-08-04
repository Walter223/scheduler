defmodule SchedulerApi.Repo.Migrations.CreateServicePrices do
  use Ecto.Migration

  def change do
    create table(:service_prices) do
      add :price_cents, :integer, null: false

      add :service_id, references(:services, on_delete: :restrict), null: false

      add :vehicle_size_id, references(:vehicle_sizes, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:service_prices, [:service_id])
    create index(:service_prices, [:vehicle_size_id])

    create unique_index(
             :service_prices,
             [:service_id, :vehicle_size_id]
           )

    create constraint(
             :service_prices,
             :price_cents_must_be_positive,
             check: "price_cents > 0"
           )
  end
end
