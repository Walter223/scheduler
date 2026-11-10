defmodule SchedulerApi.Repo.Migrations.AddOnboardingGuideState do
  use Ecto.Migration

  def change do
    alter table(:business_onboarding_drafts) do
      add :guide_state, :map, null: false, default: %{}
    end
  end
end
