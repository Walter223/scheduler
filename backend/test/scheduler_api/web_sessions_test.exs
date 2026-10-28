defmodule SchedulerApi.WebSessionsTest do
  use SchedulerApi.DataCase, async: true
  alias SchedulerApi.Accounts
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  import SchedulerApi.AccountsFixtures
  @now ~U[2026-10-28 12:00:00Z]

  setup do
    %{user: active_user_fixture(%{}, now: @now)}
  end

  defp create(user, opts \\ []) do
    {:ok, session, credential} = Accounts.create_session(user, Keyword.merge([now: @now], opts))
    {session, SessionCredential.reveal(credential), credential}
  end

  test "credential is a fresh 256-bit canonical Base64URL value; only SHA256 of serialized token is stored",
       %{user: user} do
    {session, token, credential} = create(user)
    assert byte_size(token) == 43
    assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert {:ok, bytes} = Base.url_decode64(token, padding: false)
    assert byte_size(bytes) == 32
    stored = Repo.get!(WebSession, session.id)
    assert stored.token_hash == :crypto.hash(:sha256, token)
    refute stored.token_hash == :crypto.hash(:sha256, bytes)
    assert byte_size(stored.token_hash) == 32
    refute inspect(credential) =~ token
    refute inspect({:ok, session, credential}) =~ token
    {_other, other_token, _} = create(user)
    refute other_token == token

    assert MapSet.new(WebSession.__schema__(:fields)) ==
             MapSet.new([
               :id,
               :user_id,
               :token_hash,
               :inserted_at,
               :updated_at,
               :last_seen_at,
               :idle_expires_at,
               :absolute_expires_at,
               :revoked_at,
               :revocation_reason
             ])

    # Actual persisted JSON contains neither the raw credential nor token/provider columns.
    %{rows: [[json]]} =
      Repo.query!("SELECT row_to_json(s)::text FROM web_sessions s WHERE id=$1", [session.id])

    refute json =~ token
  end

  test "valid active verified user resolves with current account preloaded", %{user: user} do
    {session, token, _} = create(user)
    assert {:ok, resolved} = Accounts.get_session_by_token(token, now: @now)
    assert resolved.id == session.id
    assert resolved.user.id == user.id
    assert resolved.user.status == :active
    assert session.inserted_at == @now
    assert session.last_seen_at == @now
    assert session.idle_expires_at == DateTime.add(@now, 1800)
    assert session.absolute_expires_at == DateTime.add(@now, 28800)
  end

  for status <- [:pending, :suspended, :deactivated] do
    test "#{status} account cannot create a session even with a stale active struct", %{
      user: stale
    } do
      {:ok, _} = Accounts.set_user_status(stale, unquote(status), now: @now)
      assert {:error, :ineligible_account} = Accounts.create_session(stale, now: @now)
      assert Repo.aggregate(WebSession, :count) == 0
    end
  end

  test "unverified-email active account cannot create a session", %{user: user} do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email_verified: false])
    assert {:error, :ineligible_account} = Accounts.create_session(user, now: @now)
  end

  test "malformed/pathological tokens and unknown canonical credentials fail safely without DB queries" do
    handler_id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:scheduler_api, :repo, :query],
        fn _, _, _, pid -> if self() == pid, do: send(pid, :unexpected_lookup_query) end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    malformed = [
      nil,
      123,
      %{},
      [],
      "",
      String.duplicate("a", 100_000),
      String.duplicate("a", 42),
      String.duplicate("a", 44),
      String.duplicate("!", 43),
      :binary.copy(<<255>>, 43),
      String.duplicate("a", 42) <> "=",
      String.duplicate("a", 42) <> "B"
    ]

    for token <- malformed do
      assert {:error, :invalid_session} = Accounts.get_session_by_token(token, now: @now)
    end

    refute_received :unexpected_lookup_query
    :telemetry.detach(handler_id)

    unknown = SessionCredential.generate() |> SessionCredential.reveal()
    assert {:error, :invalid_session} = Accounts.get_session_by_token(unknown, now: @now)
  end

  test "unpersisted/stale identifiers fail cleanly without trusting supplied metadata", %{
    user: user
  } do
    assert {:error, :user_not_found} = Accounts.create_session(%User{}, now: @now)
    assert {:error, :invalid_session} = Accounts.touch_session(%WebSession{}, now: @now)

    assert {:error, :invalid_session} =
             Accounts.revoke_session(%WebSession{id: -1}, :logout, now: @now)

    {session, _token, _} = create(user)
    other = active_user_fixture(%{}, now: @now)
    # A forged user_id on an internal struct does not change the persisted owner.
    assert {:ok, updated} = Accounts.touch_session(%{session | user_id: other.id}, now: @now)
    assert updated.user_id == user.id
  end

  test "idle expiry is strictly exclusive at exact boundary", %{user: user} do
    {session, token, _} = create(user)

    assert {:ok, _} =
             Accounts.get_session_by_token(token, now: DateTime.add(session.idle_expires_at, -1))

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: session.idle_expires_at)

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: DateTime.add(session.idle_expires_at, 1))

    assert {:error, :invalid_session} =
             Accounts.touch_session(session, now: session.idle_expires_at)
  end

  test "absolute expiry is strictly exclusive even with long idle timeout", %{user: user} do
    {session, token, _} = create(user, idle_timeout_seconds: 100, absolute_lifetime_seconds: 10)
    assert session.idle_expires_at == session.absolute_expires_at
    assert {:ok, _} = Accounts.get_session_by_token(token, now: DateTime.add(@now, 9))

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: DateTime.add(@now, 10))

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: DateTime.add(@now, 11))

    assert {:error, :invalid_session} =
             Accounts.touch_session(session, now: session.absolute_expires_at)
  end

  test "touch advances idle, caps it at absolute and never moves absolute or last-seen backwards",
       %{user: user} do
    {session, token, _} = create(user, idle_timeout_seconds: 10, absolute_lifetime_seconds: 25)

    assert {:ok, first} =
             Accounts.touch_session(session, now: DateTime.add(@now, 8), idle_timeout_seconds: 10)

    assert first.last_seen_at == DateTime.add(@now, 8)
    assert first.idle_expires_at == DateTime.add(@now, 18)
    assert first.absolute_expires_at == session.absolute_expires_at
    # Stale metadata cannot overwrite a more recent touch.
    assert {:ok, older} =
             Accounts.touch_session(session, now: DateTime.add(@now, 7), idle_timeout_seconds: 10)

    assert older.last_seen_at == first.last_seen_at
    assert older.idle_expires_at == first.idle_expires_at

    assert {:ok, capped} =
             Accounts.touch_session(session,
               now: DateTime.add(@now, 17),
               idle_timeout_seconds: 10
             )

    assert capped.idle_expires_at == session.absolute_expires_at
    assert capped.absolute_expires_at == session.absolute_expires_at
    assert {:ok, _} = Accounts.get_session_by_token(token, now: DateTime.add(@now, 24))

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: DateTime.add(@now, 25))
  end

  for status <- [:suspended, :deactivated, :pending] do
    test "current #{status} status invalidates lookup and touch even if session row is otherwise valid",
         %{user: user} do
      {session, token, _} = create(user)
      # Bypass lifecycle helper to prove the lookup itself checks current user state.
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: unquote(status)])
      assert is_nil(Repo.get!(WebSession, session.id).revoked_at)
      assert {:error, :invalid_session} = Accounts.get_session_by_token(token, now: @now)
      assert {:error, :invalid_session} = Accounts.touch_session(session, now: @now)
    end
  end

  test "identity sync to unverified email immediately invalidates existing session", %{user: user} do
    {session, token, _} = create(user)

    identity =
      verified_identity_fixture(%{
        issuer: user.keycloak_issuer,
        subject: user.keycloak_subject,
        email_verified: false
      })

    assert {:ok, updated} = Accounts.sync_verified_identity(identity, now: @now)
    assert updated.status == :active
    assert {:error, :invalid_session} = Accounts.get_session_by_token(token, now: @now)
    assert {:error, :invalid_session} = Accounts.touch_session(session, now: @now)
  end

  test "single-session revocation is durable/idempotent and does not revoke others", %{user: user} do
    {session, token, _} = create(user)
    {_other, other_token, _} = create(user)
    assert {:ok, revoked} = Accounts.revoke_session(session, :logout, now: @now)
    assert revoked.revoked_at == @now
    assert revoked.revocation_reason == :logout
    assert {:error, :invalid_session} = Accounts.get_session_by_token(token, now: @now)
    assert {:error, :invalid_session} = Accounts.touch_session(session, now: @now)
    assert {:ok, _} = Accounts.get_session_by_token(other_token, now: @now)

    assert {:ok, repeated} =
             Accounts.revoke_session(session, :security_event, now: DateTime.add(@now, 1))

    assert repeated.revoked_at == revoked.revoked_at
    assert repeated.revocation_reason == :logout
  end

  test "revoke-all immediately rejects every session for only that user", %{user: user} do
    {_first, token_a, _} = create(user)
    {_second, token_b, _} = create(user)
    other = active_user_fixture(%{}, now: @now)
    {_third, other_token, _} = create(other)
    assert {:ok, 2} = Accounts.revoke_all_sessions_for_user(user, :security_event, now: @now)
    assert {:ok, 0} = Accounts.revoke_all_sessions_for_user(user, :admin_sign_out, now: @now)

    for token <- [token_a, token_b],
        do: assert({:error, :invalid_session} == Accounts.get_session_by_token(token, now: @now))

    assert {:ok, _} = Accounts.get_session_by_token(other_token, now: @now)
  end

  test "suspension durably revokes sessions so reactivation cannot resurrect credentials", %{
    user: user
  } do
    {session, token, _} = create(user)
    assert {:ok, suspended} = Accounts.set_user_status(user, :suspended, now: @now)
    assert Repo.get!(WebSession, session.id).revocation_reason == :account_suspended
    assert {:ok, _} = Accounts.set_user_status(suspended, :active, now: @now)
    assert {:error, :invalid_session} = Accounts.get_session_by_token(token, now: @now)
  end

  test "revocation reasons reject arbitrary sensitive/unbounded strings", %{user: user} do
    {session, token, _} = create(user)

    for reason <- ["customer email", String.duplicate("x", 100_000), :unknown, nil] do
      assert {:error, :invalid_revocation_reason} =
               Accounts.revoke_session(session, reason, now: @now)

      assert {:error, :invalid_revocation_reason} =
               Accounts.revoke_all_sessions_for_user(user, reason, now: @now)
    end

    assert {:ok, _} = Accounts.get_session_by_token(token, now: @now)
  end

  test "database enforces digest length/uniqueness, expiry consistency and restricted user deletion",
       %{user: user} do
    {session, _token, _} = create(user)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               """
               INSERT INTO web_sessions (user_id,token_hash,last_seen_at,idle_expires_at,absolute_expires_at,inserted_at,updated_at)
               SELECT user_id,token_hash,last_seen_at,idle_expires_at,absolute_expires_at,inserted_at,updated_at
               FROM web_sessions WHERE id=$1
               """,
               [session.id],
               mode: :savepoint
             )

    for {sql, params} <- [
          {"UPDATE web_sessions SET token_hash=$1 WHERE id=$2", [<<0>>, session.id]},
          {"UPDATE web_sessions SET idle_expires_at=absolute_expires_at + interval '1 second' WHERE id=$1",
           [session.id]},
          {"UPDATE web_sessions SET revocation_reason='email@example.invalid' WHERE id=$1",
           [session.id]}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(sql, params, mode: :savepoint)
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM users WHERE id=$1", [user.id], mode: :savepoint)

    assert Repo.get!(WebSession, session.id)
  end

  test "clock/policy overrides are deterministic, bounded and reject malformed input", %{
    user: user
  } do
    for opts <- [
          [now: nil],
          [idle_timeout_seconds: 0],
          [absolute_lifetime_seconds: -1],
          [idle_timeout_seconds: "30"],
          [absolute_lifetime_seconds: 1_000_000_000]
        ] do
      assert {:error, :invalid_options} =
               Accounts.create_session(user, Keyword.merge([now: @now], opts))
    end

    {session, token, _} =
      create(user,
        now: ~U[2026-10-28 12:00:00.123456Z],
        idle_timeout_seconds: 2,
        absolute_lifetime_seconds: 3
      )

    assert session.inserted_at == @now
    assert {:ok, _} = Accounts.get_session_by_token(token, now: DateTime.add(@now, 1))

    assert {:error, :invalid_session} =
             Accounts.get_session_by_token(token, now: DateTime.add(@now, 2))
  end
end
