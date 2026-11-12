defmodule SchedulerApi.Authentication.Browser do
  @moduledoc "Browser use cases. OIDC exchange completes before any local session transaction."
  alias SchedulerApi.{Accounts, Authentication, Repo}
  alias SchedulerApi.Authentication.{Protocol, Provider}
  import Ecto.Query

  def begin_login(purpose \\ :login, register \\ false) do
    with true <- is_boolean(register) and (not register or purpose == :signup),
         {:ok, config, context} <- provider_context(),
         {:ok, attempt} <- Authentication.create_login_transaction(config, purpose: purpose),
         {:ok, url} <- Protocol.authorization_url(attempt, config, context, register: register) do
      {:ok, attempt, url}
    end
  end

  def complete_login(params, binding, previous_token) do
    with {:ok, login} <- Authentication.consume_login_transaction(params["state"], binding) do
      result = finish_login(login, params, binding, previous_token)

      case result do
        {:error, reason} when login.purpose == :signup -> {:error, {:signup, reason}}
        _ -> result
      end
    end
  end

  defp finish_login(login, params, binding, previous_token) do
    with false <- Map.has_key?(params, "error"),
         {:ok, config, context} <- provider_context(),
         {:ok, identity} <- Protocol.exchange_code(params["code"], login, config, context),
         {:ok, user} <- Accounts.sync_verified_identity(identity) do
      if login.purpose == :signup do
        SchedulerApi.Provisioning.Onboarding.issue_after_oidc(user, binding)
      else
        previous =
          case Accounts.get_session_by_token(previous_token) do
            {:ok, session} -> session
            _ -> nil
          end

        Repo.transaction(fn ->
          # Account replacement can span two users. Lock their rows in ID order
          # before the existing Accounts user-then-session operations.
          ids = if previous, do: [user.id, previous.user_id], else: [user.id]

          Repo.all(
            from u in SchedulerApi.Accounts.User,
              where: u.id in ^ids,
              order_by: u.id,
              lock: "FOR UPDATE"
          )

          case Accounts.create_session(user) do
            {:ok, session, credential} ->
              case previous do
                %SchedulerApi.Accounts.WebSession{} ->
                  case Accounts.revoke_session(previous, :session_rotation) do
                    {:ok, _} -> :ok
                    {:error, _} -> Repo.rollback(:session_unavailable)
                  end

                _ ->
                  :ok
              end

              {session, credential}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      end
    else
      true -> {:error, :login_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_context do
    # Tests replace discovery only with signed local provider fixtures, never verification.
    Application.get_env(:scheduler_api, :oidc_provider, Provider).context()
  end
end
