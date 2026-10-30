defmodule SchedulerApi.Employment.RehireAudit do
  use Ecto.Schema

  schema "employment_rehire_audits" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employee, SchedulerApi.Employment.EmploymentRecord
    belongs_to :previous_period, SchedulerApi.Employment.EmploymentRecord
    belongs_to :period, SchedulerApi.Employment.EmploymentRecord
    field :occurred_at, :utc_datetime
  end
end
