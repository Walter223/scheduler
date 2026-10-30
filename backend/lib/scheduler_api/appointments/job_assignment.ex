defmodule SchedulerApi.Appointments.JobAssignment do
  use Ecto.Schema

  schema "appointment_assignments" do
    belongs_to :appointment, SchedulerApi.Appointments.Appointment
    belongs_to :assignment, SchedulerApi.Employment.ShopAssignment
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :work_shift, SchedulerApi.Employment.WorkShift
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :status, Ecto.Enum, values: [:active, :reassigned, :unassigned], default: :active
    field :closed_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
