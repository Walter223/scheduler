defmodule SchedulerApi.Employment.WorkShiftAuditEvent do
  use Ecto.Schema

  schema "work_shift_audit_events" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :assignment, SchedulerApi.Employment.ShopAssignment
    belongs_to :shift, SchedulerApi.Employment.WorkShift
    belongs_to :replacement_shift, SchedulerApi.Employment.WorkShift
    field :action, Ecto.Enum, values: [:create, :cancel, :reschedule]
    field :outcome, Ecto.Enum, values: [:applied, :denied]

    field :reason, Ecto.Enum,
      values: [
        :created,
        :cancelled,
        :rescheduled,
        :forbidden,
        :invalid_input,
        :ineligible_assignment,
        :overlap,
        :not_active,
        :unchanged
      ]

    field :occurred_at, :utc_datetime
  end
end
