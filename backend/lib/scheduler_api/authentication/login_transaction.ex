defmodule SchedulerApi.Authentication.LoginTransaction do
  @moduledoc "Short-lived server-only OIDC transaction. All protocol material is Inspect-redacted."
  use Ecto.Schema
  @derive {Inspect, only: [:id, :expires_at, :consumed_at]}
  schema "login_transactions" do
    field :issuer, :string
    field :client_id, :string
    field :callback_url, :string
    field :state_hash, :binary
    field :browser_binding_hash, :binary
    field :nonce, :string, redact: true
    field :pkce_verifier, :string, redact: true
    field :return_path, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
