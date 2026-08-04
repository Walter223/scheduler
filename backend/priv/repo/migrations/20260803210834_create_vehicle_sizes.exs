defmodule SchedulerApi.Repo.Migrations.CreateVehicleSizes do
  use Ecto.Migration

  def change do
    create table(:vehicle_sizes) do
      add :name, :string, null: false
      add :sort_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vehicle_sizes, [:name])
    create unique_index(:vehicle_sizes, [:sort_order])

    create constraint(
             :vehicle_sizes,
             :sort_order_must_be_positive,
             check: "sort_order > 0"
           )
  end
end
