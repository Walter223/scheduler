defmodule SchedulerApi.Repo.Migrations.CreateLoginTransactions do
  use Ecto.Migration

  def change do
    create table(:login_transactions) do
      add :issuer, :string, size: 1024, null: false
      add :client_id, :string, size: 100, null: false
      add :callback_url, :string, size: 2048, null: false
      add :state_hash, :binary, null: false
      add :browser_binding_hash, :binary, null: false
      add :nonce, :string, size: 43
      add :pkce_verifier, :string, size: 43
      add :return_path, :string, size: 1, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:login_transactions, [:state_hash])
    create unique_index(:login_transactions, [:browser_binding_hash])
    create index(:login_transactions, [:expires_at])

    create constraint(:login_transactions, :login_transaction_hash_lengths,
             check: "octet_length(state_hash) = 32 AND octet_length(browser_binding_hash) = 32"
           )

    create constraint(:login_transactions, :login_transaction_return_path,
             check: "return_path = '/'"
           )

    create constraint(:login_transactions, :login_transaction_lifetime,
             check: "expires_at = inserted_at + interval '10 minutes'"
           )

    create constraint(:login_transactions, :login_transaction_secrets,
             check:
               "(consumed_at IS NULL AND nonce ~ '^[A-Za-z0-9_-]{43}$' AND pkce_verifier ~ '^[A-Za-z0-9_-]{43}$' AND nonce IS NOT NULL AND pkce_verifier IS NOT NULL) OR (consumed_at IS NOT NULL AND nonce IS NULL AND pkce_verifier IS NULL)"
           )
  end
end
