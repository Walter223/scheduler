defmodule SchedulerApi.Appointments.JobAssignmentAuditEvent do
  use Ecto.Schema

  schema "appointment_assignment_audit_events" do
    belongs_to :actor_user, SchedulerApi.Accounts.User
    belongs_to :appointment, SchedulerApi.Appointments.Appointment
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :job, SchedulerApi.Appointments.JobAssignment
    belongs_to :replacement_job, SchedulerApi.Appointments.JobAssignment
    field :action, Ecto.Enum, values: [:assign, :reassign, :unassign]
    field :outcome, Ecto.Enum, values: [:applied, :denied]
    field :reason, :string
    field :occurred_at, :utc_datetime
  end
end
