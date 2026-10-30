defmodule SchedulerApi.Employment.CompensationAuditEvent do
  use Ecto.Schema

  schema "compensation_audit_events" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :rate, SchedulerApi.Employment.CompensationRate
    belongs_to :closed_rate, SchedulerApi.Employment.CompensationRate
    field :closed_effective_until, :date
    field :action, Ecto.Enum, values: [:set_rate], default: :set_rate
    field :outcome, Ecto.Enum, values: [:applied, :denied]

    field :reason, Ecto.Enum,
      values: [
        :created,
        :forbidden,
        :invalid_input,
        :employment_ended,
        :invalid_effective_date,
        :effective_date_conflict
      ]

    field :occurred_at, :utc_datetime
  end
end
