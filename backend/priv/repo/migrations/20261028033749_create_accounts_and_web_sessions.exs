defmodule SchedulerApi.Repo.Migrations.CreateAccountsAndWebSessions do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :keycloak_issuer, :text, null: false
      add :keycloak_subject, :text, null: false
      add :email, :string, size: 320, null: false
      add :email_verified, :boolean, null: false, default: false
      add :first_name, :string
      add :last_name, :string
      add :status, :string, null: false, default: "pending"
      add :last_authenticated_at, :utc_datetime, null: false
      add :profile_synced_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:keycloak_issuer, :keycloak_subject])

    create constraint(:users, :users_status_valid,
             check: "status IN ('pending', 'active', 'suspended', 'deactivated')"
           )

    for field <- [:keycloak_issuer, :keycloak_subject] do
      create constraint(:users, "users_#{field}_valid",
               check: "btrim(#{field}) <> '' AND octet_length(#{field}) <= 1024"
             )
    end

    create constraint(:users, :users_email_not_blank, check: "btrim(email) <> ''")

    create table(:web_sessions) do
      add :user_id, references(:users, on_delete: :restrict), null: false
      add :token_hash, :binary, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :idle_expires_at, :utc_datetime, null: false
      add :absolute_expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :revocation_reason, :string, size: 32
      timestamps(type: :utc_datetime)
    end

    create unique_index(:web_sessions, [:token_hash])
    create index(:web_sessions, [:user_id])
    create index(:web_sessions, [:absolute_expires_at])

    create constraint(:web_sessions, :web_sessions_token_hash_length,
             check: "octet_length(token_hash) = 32"
           )

    create constraint(:web_sessions, :web_sessions_expiration_valid,
             check:
               "last_seen_at >= inserted_at AND idle_expires_at > last_seen_at AND " <>
                 "idle_expires_at <= absolute_expires_at"
           )

    create constraint(:web_sessions, :web_sessions_revocation_valid,
             check:
               "(revoked_at IS NULL AND revocation_reason IS NULL) OR " <>
                 "(revoked_at IS NOT NULL AND revocation_reason IS NOT NULL AND " <>
                 "revocation_reason IN ('logout', 'account_pending', 'account_suspended', " <>
                 "'account_deactivated', 'security_event', 'recovery', 'admin_sign_out', " <>
                 "'credential_compromise', 'session_rotation'))"
           )
  end
end
