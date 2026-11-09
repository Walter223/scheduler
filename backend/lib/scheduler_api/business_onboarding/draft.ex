defmodule SchedulerApi.BusinessOnboarding.Draft do
  @moduledoc false
  use Ecto.Schema

  schema "business_onboarding_drafts" do
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :created_by_user, SchedulerApi.Accounts.User
    field :schema_version, :integer, default: 1
    field :revision, :integer, default: 0
    field :state, :string, default: "provisioning_complete"
    field :proposal, :map, redact: true
    timestamps(type: :utc_datetime)
  end
end
