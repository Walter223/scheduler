defmodule SchedulerApi.Accounts do
  @moduledoc """
  Internal identity/account and revocable web-session primitives only.
  No OIDC verification, HTTP handlers, cookies or application authorization.
  All clocks use UTC whole seconds; `:now` is injectable for deterministic tests.
  """
  import Ecto.Query
  alias SchedulerApi.Repo
  alias SchedulerApi.Accounts.{SessionCredential, User, VerifiedIdentity, WebSession}

  @profile_fields [
    :email,
    :email_verified,
    :first_name,
    :last_name,
    :last_authenticated_at,
    :profile_synced_at,
    :updated_at
  ]
  @max_timeout_seconds 31_536_000

  @doc "Sync only an already verified identity. Unknown identities remain pending; email is never a key."
  def sync_verified_identity(identity, opts \\ [])

  def sync_verified_identity(%VerifiedIdentity{email_verified: verified} = identity, opts)
      when is_boolean(verified) do
    with {:ok, now} <- clock(opts),
         {:ok, authenticated_at} <- utc_seconds(identity.authenticated_at || now) do
      identity
      |> User.identity_changeset(now, authenticated_at)
      |> Repo.insert(
        on_conflict: {:replace, @profile_fields},
        conflict_target: [:keycloak_issuer, :keycloak_subject],
        returning: true
      )
    end
  end

  def sync_verified_identity(_, _), do: {:error, :unverified_identity}

  def get_user(id), do: Repo.get(User, id)

  @doc "Trusted local lifecycle operation, not activation policy or authorization. Blocks revoke existing sessions."
  def set_user_status(%User{id: id}, status, opts \\ []) do
    with {:ok, now} <- clock(opts) do
      Repo.transaction(fn ->
        user = lock_user!(id)

        updated =
          user
          |> User.status_changeset(status)
          |> Ecto.Changeset.put_change(:updated_at, now)
          |> persist!()

        if updated.status != :active do
          revoke_user_sessions(id, status_reason(updated.status), now)
        end

        updated
      end)
    end
  end

  @doc "Returns {:ok, session, inspect-redacted credential}. Reveal once for delivery; no raw token is persisted."
  def create_session(%User{id: id}, opts \\ []) do
    with {:ok, now} <- clock(opts), {:ok, policy} <- policy(opts) do
      result =
        Repo.transaction(fn ->
          # User first, session second is the common lock order for all mutations.
          # Re-read persisted eligibility, never trust a stale caller's User struct.
          user = lock_user!(id)
          require_eligible!(user)
          credential = SessionCredential.generate()

          {:ok, digest} =
            credential |> SessionCredential.reveal() |> SessionCredential.hash_presented()

          absolute = DateTime.add(now, policy.absolute)

          session =
            %WebSession{
              user_id: user.id,
              token_hash: digest,
              inserted_at: now,
              updated_at: now,
              last_seen_at: now,
              absolute_expires_at: absolute,
              idle_expires_at: earlier(DateTime.add(now, policy.idle), absolute)
            }
            |> WebSession.creation_changeset()
            |> persist!()

          {session, credential}
        end)

      case result do
        {:ok, {session, credential}} -> {:ok, session, credential}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Hashes a canonical presented credential; checks current account eligibility and both strict expirations."
  def get_session_by_token(token, opts \\ []) do
    with {:ok, digest} <- SessionCredential.hash_presented(token), {:ok, now} <- clock(opts) do
      session =
        Repo.one(
          from s in WebSession,
            join: u in assoc(s, :user),
            where:
              s.token_hash == ^digest and is_nil(s.revoked_at) and
                s.idle_expires_at > ^now and s.absolute_expires_at > ^now and
                u.status == :active and u.email_verified == true,
            preload: [user: u]
        )

      if session, do: {:ok, session}, else: {:error, :invalid_session}
    end
  end

  @doc "Touches only a currently valid session; idle expiry is monotonic and capped by immutable absolute expiry."
  def touch_session(%WebSession{} = session, opts \\ []) do
    with {:ok, now} <- clock(opts), {:ok, policy} <- policy(opts) do
      with_locked_session(session, fn current, user ->
        if not usable?(current, user, now), do: Repo.rollback(:invalid_session)
        idle = later(current.idle_expires_at, DateTime.add(now, policy.idle))

        current
        |> Ecto.Changeset.change(
          last_seen_at: later(current.last_seen_at, now),
          idle_expires_at: earlier(idle, current.absolute_expires_at),
          updated_at: later(current.updated_at, now)
        )
        |> persist!()
      end)
    end
  end

  @doc "Durably revokes one session; first revocation timestamp/reason are preserved."
  def revoke_session(%WebSession{} = session, reason, opts \\ []) do
    with :ok <- valid_reason(reason), {:ok, now} <- clock(opts) do
      with_locked_session(session, fn current, _user ->
        if current.revoked_at do
          current
        else
          current
          |> Ecto.Changeset.change(revoked_at: now, revocation_reason: reason, updated_at: now)
          |> persist!()
        end
      end)
    end
  end

  @doc "Revokes all unrevoked sessions for the authoritative user; returns {:ok, count}."
  def revoke_all_sessions_for_user(%User{id: id}, reason, opts \\ []) do
    with :ok <- valid_reason(reason), {:ok, now} <- clock(opts) do
      Repo.transaction(fn ->
        lock_user!(id)
        revoke_user_sessions(id, reason, now)
      end)
    end
  end

  # Retention/deletion policy and cleanup scheduling are intentionally deferred.
  # Expired/revoked rows cannot authenticate and remain available for history.

  defp lock_user!(id) when is_integer(id) and id > 0 do
    Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:user_not_found)
  end

  defp lock_user!(_), do: Repo.rollback(:user_not_found)

  defp with_locked_session(%WebSession{id: id}, fun) when is_integer(id) and id > 0 do
    Repo.transaction(fn ->
      metadata = Repo.get(WebSession, id) || Repo.rollback(:invalid_session)
      user = lock_user!(metadata.user_id)

      current =
        Repo.one(
          from s in WebSession,
            where: s.id == ^id and s.user_id == ^user.id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:invalid_session)

      fun.(current, user)
    end)
  end

  defp with_locked_session(_, _), do: {:error, :invalid_session}

  defp require_eligible!(%User{status: :active, email_verified: true}), do: :ok
  defp require_eligible!(_), do: Repo.rollback(:ineligible_account)

  defp usable?(session, user, now) do
    user.status == :active and user.email_verified and is_nil(session.revoked_at) and
      DateTime.compare(now, session.idle_expires_at) == :lt and
      DateTime.compare(now, session.absolute_expires_at) == :lt
  end

  defp revoke_user_sessions(id, reason, now) do
    {count, _} =
      Repo.update_all(from(s in WebSession, where: s.user_id == ^id and is_nil(s.revoked_at)),
        set: [revoked_at: now, revocation_reason: reason, updated_at: now]
      )

    count
  end

  defp valid_reason(reason) do
    if reason in WebSession.revocation_reasons(),
      do: :ok,
      else: {:error, :invalid_revocation_reason}
  end

  defp status_reason(:pending), do: :account_pending
  defp status_reason(:suspended), do: :account_suspended
  defp status_reason(:deactivated), do: :account_deactivated

  defp persist!(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: utc_seconds(Keyword.get(opts, :now, DateTime.utc_now())),
      else: {:error, :invalid_options}
  end

  defp clock(_), do: {:error, :invalid_options}

  defp utc_seconds(%DateTime{calendar: Calendar.ISO} = datetime) do
    DateTime.from_unix(DateTime.to_unix(datetime, :second), :second)
  end

  defp utc_seconds(_), do: {:error, :invalid_options}

  defp policy(opts) do
    defaults = Application.fetch_env!(:scheduler_api, __MODULE__)

    idle =
      Keyword.get(opts, :idle_timeout_seconds, Keyword.fetch!(defaults, :idle_timeout_seconds))

    absolute =
      Keyword.get(
        opts,
        :absolute_lifetime_seconds,
        Keyword.fetch!(defaults, :absolute_lifetime_seconds)
      )

    if is_integer(idle) and idle > 0 and idle <= @max_timeout_seconds and
         is_integer(absolute) and absolute > 0 and absolute <= @max_timeout_seconds do
      {:ok, %{idle: idle, absolute: absolute}}
    else
      {:error, :invalid_options}
    end
  end

  defp earlier(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
end
