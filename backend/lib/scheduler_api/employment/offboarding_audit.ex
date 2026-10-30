defmodule SchedulerApi.Employment.OffboardingAudit do
  use Ecto.Schema

  schema "employment_offboarding_audits" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :membership, SchedulerApi.Organizations.BusinessMembership
    field :ended_on, :date
    field :jobs_removed, :integer
    field :shifts_cancelled, :integer
    field :assignments_ended, :integer
    field :occurred_at, :utc_datetime
  end
end
