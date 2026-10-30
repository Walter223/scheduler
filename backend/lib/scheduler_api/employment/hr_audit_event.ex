defmodule SchedulerApi.Employment.HrAuditEvent do
  use Ecto.Schema

  schema "employment_hr_audit_events" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :assignment, SchedulerApi.Employment.ShopAssignment
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :classification_history, SchedulerApi.Employment.ClassificationHistory

    field :action, Ecto.Enum,
      values: [:create, :edit_contact, :change_classification, :assign_shop, :end_shop]

    field :outcome, Ecto.Enum, values: [:applied, :denied]
    field :reason, :string
    field :changed_fields, {:array, :string}, default: []
    field :occurred_at, :utc_datetime
  end
end
