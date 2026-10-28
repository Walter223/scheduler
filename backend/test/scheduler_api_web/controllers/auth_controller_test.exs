defmodule SchedulerApiWeb.AuthControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import SchedulerApi.OidcFixtures
  import SchedulerApi.AccountsFixtures
  import Ecto.Query
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  alias SchedulerApi.Authentication.{BrowserConfig, Credential, LoginTransaction}
  alias SchedulerApiWeb.BrowserSession

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    old = Application.get_env(:scheduler_api, :oidc_provider)
    Application.put_env(:scheduler_api, :oidc_provider, SchedulerApi.BrowserTestProvider)

    on_exit(fn ->
      if old,
        do: Application.put_env(:scheduler_api, :oidc_provider, old),
        else: Application.delete_env(:scheduler_api, :oidc_provider)
    end)

    config = config()
    storage = start_supervised!({Agent, fn -> nil end})

    pid =
      start_supervised!(
        {Bandit,
         plug:
           {SchedulerApi.OidcTestProvider,
            fn conn ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              request = URI.decode_query(body)

              unless Enum.any?(
                       Plug.Conn.get_req_header(conn, "authorization"),
                       &String.starts_with?(&1, "Basic ")
                     ),
                     do: raise("Expected confidential-client Basic authentication")

              {login, changes, response_status} = Agent.get(storage, & &1)

              if request["code_verifier"] != login.pkce_verifier or
                   request["redirect_uri"] != config.callback_url or
                   request["grant_type"] != "authorization_code",
                 do: raise("Protocol contract failed")

              claims = claims(config, login.nonce, DateTime.utc_now()) |> Map.merge(changes)

              response =
                if response_status == 200,
                  do: %{
                    id_token: sign(key, claims),
                    access_token: "synthetic-access",
                    token_type: "Bearer"
                  },
                  else: %{error: "invalid_grant"}

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(response_status, Jason.encode!(response))
            end},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    context = context(key, config)

    context = %{
      context
      | provider_configuration: %{
          context.provider_configuration
          | token_endpoint: "http://127.0.0.1:#{port}/token"
        }
    }

    Process.put(:browser_test_provider, {:ok, config, context})
    %{config: config, storage: storage}
  end

  defp start_login(c, changes \\ %{}, status \\ 200) do
    conn = get(build_conn(), "/auth/login")
    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {:ok, hash} = Credential.hash(params["state"])
    login = Repo.get_by!(LoginTransaction, state_hash: hash)
    Agent.update(c.storage, fn _ -> {login, changes, status} end)
    {conn, params, login}
  end

  defp callback(conn, params),
    do: conn |> recycle() |> get("/auth/callback", Map.put(params, "code", "synthetic-code"))

  defp active(c),
    do: active_user_fixture(%{issuer: c.config.issuer, subject: "opaque|subject/not-a-uuid"})

  defp session(user) do
    {:ok, stored, credential} = Accounts.create_session(user)
    {stored, SessionCredential.reveal(credential)}
  end

  defp authed(token), do: put_req_cookie(build_conn(), BrowserSession.session_name(), token)

  defp csrf(token),
    do: authed(token) |> get("/api/me") |> json_response(200) |> Map.fetch!("csrf_token")

  defp logout(token, csrf_token, origin \\ "http://localhost:5173") do
    authed(token)
    |> put_req_header("origin", origin)
    |> put_req_header("x-csrf-token", csrf_token)
    |> post("/auth/logout")
  end

  test "login uses independent binding, S256, exact callback and fixed destination", c do
    {conn, params, login} = start_login(c)
    assert params["response_type"] == "code"
    assert params["scope"] == "openid profile email"
    assert params["code_challenge_method"] == "S256"
    assert params["redirect_uri"] == c.config.callback_url
    refute Map.has_key?(params, "prompt")
    binding = conn.resp_cookies[BrowserSession.binding_name()]
    assert binding.http_only and binding.same_site == "Lax" and binding.path == "/"
    assert binding.max_age == 600 and binding.secure == false
    refute Map.has_key?(binding, :domain)
    refute binding.value == params["state"]
    refute Map.has_key?(conn.resp_cookies, BrowserSession.session_name())
    assert login.return_path == "/"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "real signed callback creates fresh session and retires previous session/CSRF", c do
    user = active(c)
    {previous, previous_token} = session(user)
    old_csrf = csrf(previous_token)
    {conn, params, login} = start_login(c)
    binding = conn.resp_cookies[BrowserSession.binding_name()].value
    conn = conn |> recycle() |> put_req_cookie(BrowserSession.session_name(), previous_token)
    response = get(conn, "/auth/callback", Map.put(params, "code", "synthetic-code"))
    assert redirected_to(response) == "http://localhost:5173/"
    cookie = response.resp_cookies[BrowserSession.session_name()]
    assert cookie.http_only and cookie.path == "/" and cookie.same_site == "Lax"
    refute Map.has_key?(cookie, :max_age)
    refute Map.has_key?(cookie, :domain)
    refute cookie.value in [previous_token, binding, params["state"]]
    assert {:ok, current} = Accounts.get_session_by_token(cookie.value)
    assert current.user.id == user.id
    assert Repo.get!(WebSession, previous.id).revoked_at
    assert is_nil(Repo.get!(WebSession, previous.id).csrf_state)
    assert json_response(logout(cookie.value, old_csrf), 403)["error"] == "invalid_csrf_token"
    saved = Repo.get!(LoginTransaction, login.id)
    assert saved.consumed_at
    assert is_nil(saved.nonce) and is_nil(saved.pkce_verifier)
    assert response.resp_cookies[BrowserSession.binding_name()].max_age == 0
  end

  test "unknown identity remains pending and receives no session", c do
    {conn, params, _} = start_login(c)
    response = callback(conn, params)
    assert redirected_to(response) == "http://localhost:5173/?auth_error=account_unavailable"
    assert Repo.one!(User).status == :pending
    assert Repo.aggregate(WebSession, :count) == 0
    refute Map.has_key?(response.resp_cookies, BrowserSession.session_name())
  end

  for status <- [:pending, :suspended, :deactivated] do
    test "#{status} account cannot acquire a session", c do
      user = active(c)
      {:ok, _} = Accounts.set_user_status(user, unquote(status))
      {conn, params, _} = start_login(c)
      response = callback(conn, params)
      assert redirected_to(response) =~ "auth_error=account_unavailable"
      refute Map.has_key?(response.resp_cookies, BrowserSession.session_name())
    end
  end

  test "unverified email is denied", c do
    active(c)
    {conn, params, _} = start_login(c, %{"email_verified" => false})
    assert redirected_to(callback(conn, params)) =~ "auth_error=account_unavailable"
    assert Repo.aggregate(WebSession, :count) == 0
  end

  test "invalid signature claims/nonce and provider failure never issue session", c do
    active(c)

    for changes <- [%{"nonce" => "wrong"}, %{"aud" => "magnum-api"}, %{"iss" => "wrong"}] do
      {conn, params, _} = start_login(c, changes)
      assert redirected_to(callback(conn, params)) =~ "auth_error=login_failed"
    end

    {conn, params, _} = start_login(c, %{}, 503)
    assert redirected_to(callback(conn, params)) =~ "auth_error=provider_unavailable"
    assert Repo.aggregate(WebSession, :count) == 0
  end

  test "missing/wrong binding, missing state and replaced-tab binding fail", c do
    {conn, params, _} = start_login(c)

    for request <- [
          build_conn(),
          put_req_cookie(build_conn(), BrowserSession.binding_name(), nonce())
        ] do
      assert redirected_to(get(request, "/auth/callback", params)) =~ "auth_error=login_failed"
    end

    assert redirected_to(callback(conn, %{})) =~ "auth_error=login_failed"
    {new_conn, _, _} = start_login(c)
    assert redirected_to(callback(new_conn, params)) =~ "auth_error=login_failed"
  end

  test "expired, denied, and replayed transactions are unusable", c do
    {conn, params, login} = start_login(c)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    # Preserve the fixed-lifetime DB constraint while moving the entire window.
    Repo.update_all(from(t in LoginTransaction, where: t.id == ^login.id),
      set: [inserted_at: DateTime.add(now, -600), expires_at: now]
    )

    assert redirected_to(callback(conn, params)) =~ "auth_error=login_failed"
    {conn, params, login} = start_login(c)
    denied = Map.put(params, "error", "access_denied")
    assert redirected_to(callback(conn, denied)) =~ "auth_error=login_failed"
    assert Repo.get!(LoginTransaction, login.id).consumed_at
    assert redirected_to(callback(conn, params)) =~ "auth_error=login_failed"
  end

  test "status is minimal, no-store, and does not touch idle expiration", c do
    {session, token} = session(active(c))
    response = authed(token) |> get("/api/me")
    body = json_response(response, 200)
    assert Map.keys(body) |> Enum.sort() == ["authenticated", "csrf_token", "user"]
    assert body["authenticated"]
    refute response.resp_body =~ token
    assert Repo.get!(WebSession, session.id).idle_expires_at == session.idle_expires_at
    assert get_resp_header(response, "cache-control") == ["no-store"]

    for bad <- ["bad", nonce()] do
      assert json_response(authed(bad) |> get("/api/me"), 200) ==
               %{"authenticated" => false, "user" => nil, "csrf_token" => nil}
    end
  end

  test "logout needs session-specific CSRF plus exact Origin; local revocation is immediate", c do
    {session, token} = session(active(c))
    {_other, other_token} = session(Accounts.get_user(session.user_id))
    csrf = csrf(token)
    assert json_response(logout(token, csrf(other_token)), 403)["error"] == "invalid_csrf_token"
    assert json_response(logout(token, ""), 403)["error"] == "invalid_csrf_token"

    for origin <- [
          "null",
          "http://localhost:5173.evil.test",
          "http://localhost:5174",
          "https://localhost:5173"
        ] do
      assert json_response(logout(token, csrf, origin), 403)["error"] == "invalid_origin"
    end

    assert json_response(
             authed(token) |> put_req_header("x-csrf-token", csrf) |> post("/auth/logout"),
             403
           )

    Process.put(:browser_test_provider, {:error, :provider_unavailable})
    response = logout(token, csrf)
    assert json_response(response, 200) == %{"ok" => true}
    assert response.resp_cookies[BrowserSession.session_name()].max_age == 0
    assert {:error, :invalid_session} = Accounts.get_session_by_token(token)
    assert is_nil(Repo.get!(WebSession, session.id).csrf_state)
    assert json_response(logout(token, csrf), 401)["error"] == "authentication_required"
  end

  test "Referer fallback is allowed only without Origin and only at the exact origin", c do
    {_, token} = session(active(c))
    csrf = csrf(token)

    for referrer <- [
          "http://localhost:5173.evil/path",
          "//localhost:5173/",
          "http://user@localhost:5173/"
        ] do
      response =
        authed(token)
        |> put_req_header("x-csrf-token", csrf)
        |> put_req_header("referer", referrer)
        |> post("/auth/logout")

      assert response.status == 403
    end

    response =
      authed(token)
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("referer", "http://localhost:5173/account")
      |> post("/auth/logout")

    assert response.status == 200
  end

  test "suspension and expiry override otherwise-valid CSRF", c do
    user = active(c)
    {_, token} = session(user)
    csrf = csrf(token)
    {:ok, _} = Accounts.set_user_status(user, :suspended)
    assert logout(token, csrf).status == 401
    assert json_response(authed(token) |> get("/api/me"), 200)["authenticated"] == false
    {:ok, user} = Accounts.set_user_status(user, :active)
    {session, token} = session(user)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(s in WebSession, where: s.id == ^session.id),
      set: [
        idle_expires_at: now,
        last_seen_at: DateTime.add(now, -1),
        inserted_at: DateTime.add(now, -1)
      ]
    )

    assert json_response(authed(token) |> get("/api/me"), 200)["authenticated"] == false
  end

  test "production cookie attributes and origin validation fail closed" do
    old = Application.fetch_env!(:scheduler_api, :browser_auth)
    on_exit(fn -> Application.put_env(:scheduler_api, :browser_auth, old) end)
    assert {:error, _} = BrowserConfig.new("http://localhost:5173", :prod)
    assert {:ok, config} = BrowserConfig.new("https://app.example.invalid", :prod)
    Application.put_env(:scheduler_api, :browser_auth, config)
    assert BrowserSession.session_name() == "__Host-magnum_session"
    assert BrowserSession.binding_name() == "__Host-magnum_login"

    assert BrowserSession.options() == [
             http_only: true,
             secure: true,
             same_site: "Lax",
             path: "/"
           ]
  end

  test "legacy CSRF initialization preserves session deadlines and state is inspect-redacted",
       c do
    {stored, token} = session(active(c))
    Repo.update_all(from(s in WebSession, where: s.id == ^stored.id), set: [csrf_state: nil])
    first = csrf(token)
    second = csrf(token)
    current = Repo.get!(WebSession, stored.id)
    assert SchedulerApi.Accounts.SessionCSRF.valid?(current.csrf_state, first)
    assert SchedulerApi.Accounts.SessionCSRF.valid?(current.csrf_state, second)
    refute inspect(current) =~ current.csrf_state
    assert current.last_seen_at == stored.last_seen_at
    assert current.absolute_expires_at == stored.absolute_expires_at
    assert current.idle_expires_at == stored.idle_expires_at
  end

  test "request Host/forwarded headers cannot choose callback or failure destination", c do
    {conn, params, _} = start_login(c)

    response =
      conn
      |> recycle()
      |> put_req_header("x-forwarded-host", "evil.invalid")
      |> Map.put(:host, "evil.invalid")
      |> get("/auth/callback", Map.put(params, "error", "denied"))

    assert redirected_to(response) == "http://localhost:5173/?auth_error=login_failed"
    assert get_resp_header(response, "access-control-allow-origin") == []
  end

  test "malformed callback queries clear binding and redirect without debugger or secrets" do
    response = get(build_conn(), "/auth/callback?state=%FF&code=synthetic-sensitive-code")
    assert redirected_to(response) == "http://localhost:5173/?auth_error=login_failed"
    assert response.resp_cookies[BrowserSession.binding_name()].max_age == 0
    refute response.resp_body =~ "synthetic-sensitive-code"
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "provider unavailable is safe and callback secrets are absent from logs/responses", c do
    {conn, params, _} = start_login(c)

    output =
      ExUnit.CaptureLog.capture_log(fn ->
        response = callback(conn, Map.put(params, "error", "sensitive-provider-description"))
        refute response.resp_body =~ params["state"]
        refute response.resp_body =~ "sensitive-provider-description"
      end)

    refute output =~ params["state"]
    refute output =~ "synthetic-code"
    Process.put(:browser_test_provider, {:error, :provider_unavailable})
    assert redirected_to(get(build_conn(), "/auth/login")) =~ "auth_error=provider_unavailable"
  end
end
