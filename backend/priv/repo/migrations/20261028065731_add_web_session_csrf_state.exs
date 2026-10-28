defmodule SchedulerApi.Repo.Migrations.AddWebSessionCsrfState do
  use Ecto.Migration

  def change do
    alter table(:web_sessions) do
      # Existing sessions remain intact; state is initialized on first status request.
      add :csrf_state, :string, size: 24
    end

    create constraint(:web_sessions, :web_sessions_csrf_state_length,
             check: "csrf_state IS NULL OR char_length(csrf_state) = 24"
           )
  end
end
