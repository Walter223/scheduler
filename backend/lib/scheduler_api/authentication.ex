defmodule SchedulerApi.Authentication do
  @moduledoc "OIDC login transaction persistence only; no HTTP login, sessions or authorization."
  import Ecto.Query
  alias SchedulerApi.Repo

  alias SchedulerApi.Authentication.{
    Config,
    ConsumedLogin,
    Credential,
    LoginAttempt,
    LoginTransaction
  }

  @lifetime_seconds 600

  def create_login_transaction(%Config{} = config, opts \\ []) do
    with {:ok, now} <- now(opts),
         "/" <- Keyword.get(opts, :return_path, "/") do
      [state, binding, nonce, verifier] = Enum.map(1..4, fn _ -> Credential.generate() end)
      {:ok, state_hash} = Credential.hash(Credential.reveal(state))
      {:ok, binding_hash} = Credential.hash(Credential.reveal(binding))

      transaction = %LoginTransaction{
        issuer: config.issuer,
        client_id: config.client_id,
        callback_url: config.callback_url,
        state_hash: state_hash,
        browser_binding_hash: binding_hash,
        nonce: Credential.reveal(nonce),
        pkce_verifier: Credential.reveal(verifier),
        return_path: "/",
        expires_at: DateTime.add(now, @lifetime_seconds),
        inserted_at: now,
        updated_at: now
      }

      with {:ok, transaction} <- Repo.insert(transaction, log: false) do
        {:ok, %LoginAttempt{transaction: transaction, state: state, browser_binding: binding}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_return_path}
    end
  end

  def consume_login_transaction(state, binding, opts \\ []) do
    with {:ok, state_hash} <- Credential.hash(state),
         {:ok, binding_hash} <- Credential.hash(binding),
         {:ok, now} <- now(opts) do
      # Lock only while consuming/clearing secrets. Provider exchange happens AFTER commit.
      Repo.transaction(fn ->
        transaction =
          Repo.one(
            from t in LoginTransaction,
              where:
                t.state_hash == ^state_hash and t.browser_binding_hash == ^binding_hash and
                  is_nil(t.consumed_at) and t.expires_at > ^now,
              lock: "FOR UPDATE"
          )

        if is_nil(transaction), do: Repo.rollback(:invalid_login_transaction)

        material = %ConsumedLogin{
          issuer: transaction.issuer,
          client_id: transaction.client_id,
          callback_url: transaction.callback_url,
          nonce: transaction.nonce,
          pkce_verifier: transaction.pkce_verifier,
          return_path: transaction.return_path
        }

        transaction
        |> Ecto.Changeset.change(
          consumed_at: now,
          nonce: nil,
          pkce_verifier: nil,
          updated_at: now
        )
        |> Repo.update!()

        material
      end)
    end
  end

  @doc "Purge expired rows on demand; no background scheduling is installed."
  def delete_expired_login_transactions(opts \\ []) do
    with {:ok, now} <- now(opts) do
      {count, _} = Repo.delete_all(from t in LoginTransaction, where: t.expires_at <= ^now)
      {:ok, count}
    end
  end

  @doc false
  def now(opts) do
    case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
      %DateTime{utc_offset: 0, std_offset: 0} = now -> {:ok, DateTime.truncate(now, :second)}
      _ -> {:error, :invalid_options}
    end
  end
end
