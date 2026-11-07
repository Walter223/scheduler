defmodule SchedulerApi.Provisioning.Intent do
  @moduledoc false
  use Ecto.Schema

  schema "business_provisioning_intents" do
    belongs_to :owner, SchedulerApi.Accounts.User
    field :credential_hash, :binary, redact: true
    field :business_name, :string
    field :business_slug, :string
    field :shop_name, :string
    field :shop_slug, :string
    field :timezone, :string
    field :expires_at, :utc_datetime
    field :completed_at, :utc_datetime
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :membership, SchedulerApi.Organizations.BusinessMembership
    belongs_to :role_assignment, SchedulerApi.Organizations.RoleAssignment
    belongs_to :audit_event, SchedulerApi.Authorization.AuditEvent
    timestamps(type: :utc_datetime)
  end
end
