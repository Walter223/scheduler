defmodule SchedulerApi.Repo.Migrations.AddEmploymentContactFields do
  use Ecto.Migration

  def change do
    alter table(:employments) do
      add :phone, :string, size: 32
      add :email, :string, size: 320
      add :home_address, :string, size: 1000
    end

    for field <- [:phone, :email, :home_address] do
      create constraint(:employments, "employments_#{field}_not_blank",
               check: "#{field} IS NULL OR #{field} ~ '[^[:space:]]'"
             )
    end
  end
end
