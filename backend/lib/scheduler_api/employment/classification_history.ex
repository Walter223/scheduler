defmodule SchedulerApi.Employment.ClassificationHistory do
  use Ecto.Schema

  schema "employment_classification_history" do
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :business, SchedulerApi.Organizations.Business

    field :previous_classification, Ecto.Enum,
      values: SchedulerApi.Employment.EmploymentRecord.classifications()

    field :classification, Ecto.Enum,
      values: SchedulerApi.Employment.EmploymentRecord.classifications()

    field :source, Ecto.Enum, values: [:baseline, :created, :changed]
    field :occurred_at, :utc_datetime
  end
end
