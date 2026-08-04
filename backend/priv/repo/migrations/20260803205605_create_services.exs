defmodule SchedulerApi.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services) do
      add :name, :string, null: false
      add :description, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:services, [:name])
  end
end
