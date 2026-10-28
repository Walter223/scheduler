defmodule SchedulerApi.Accounts.WebSession do
  use Ecto.Schema
  import Ecto.Changeset

  @revocation_reasons [
    :logout,
    :account_pending,
    :account_suspended,
    :account_deactivated,
    :security_event,
    :recovery,
    :admin_sign_out,
    :credential_compromise,
    :session_rotation
  ]

  schema "web_sessions" do
    belongs_to :user, SchedulerApi.Accounts.User
    field :token_hash, :binary, redact: true
    field :last_seen_at, :utc_datetime
    field :idle_expires_at, :utc_datetime
    field :absolute_expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revocation_reason, Ecto.Enum, values: @revocation_reasons
    timestamps(type: :utc_datetime)
  end

  def revocation_reasons, do: @revocation_reasons

  @doc false
  def creation_changeset(session) do
    session
    |> change()
    |> validate_required([
      :user_id,
      :token_hash,
      :last_seen_at,
      :idle_expires_at,
      :absolute_expires_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_length(:token_hash, is: 32, count: :bytes)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:token_hash, name: :web_sessions_token_hash_length)
    |> check_constraint(:idle_expires_at, name: :web_sessions_expiration_valid)
  end
end
