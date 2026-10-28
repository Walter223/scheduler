defmodule SchedulerApi.Authentication.ProtocolTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.OidcFixtures
  alias SchedulerApi.{Accounts, Authentication}
  alias SchedulerApi.Accounts.VerifiedIdentity
  alias SchedulerApi.Authentication.{Credential, Protocol}

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), other_key: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    config = config()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    nonce = nonce()

    %{
      config: config,
      context: context(key, config),
      now: now,
      nonce: nonce,
      claims: claims(config, nonce, now)
    }
  end

  test "real signed token maps opaque identity and remains pending on sync", c do
    assert {:ok, %VerifiedIdentity{} = identity} = validate(c)
    assert identity.subject == "opaque|subject/not-a-uuid"
    assert identity.authenticated_at == nil
    assert {:ok, user} = Accounts.sync_verified_identity(identity, now: c.now)
    assert user.status == :pending
    assert {:error, :ineligible_account} = Accounts.create_session(user, now: c.now)
  end

  test "legitimate auth_time is preserved, not replaced with sync time", c do
    authenticated = DateTime.add(c.now, -120)
    assert {:ok, identity} = validate(c, %{"auth_time" => DateTime.to_unix(authenticated)})
    assert identity.authenticated_at == authenticated
    assert {:error, _} = validate(c, %{"auth_time" => DateTime.to_unix(c.now) + 1})
  end

  test "invalid signature is rejected by real OIDCC", c do
    token = sign(c.other_key, c.claims)

    assert {:error, :invalid_id_token} =
             Protocol.validate_id_token(token, c.nonce, c.config, c.context, now: c.now)
  end

  for {description, changes} <- [
        {"wrong issuer", %{"iss" => "https://attacker.example.invalid"}},
        {"wrong API audience", %{"aud" => "magnum-api"}},
        {"additional audience", %{"aud" => ["magnum-web", "other"]}},
        {"wrong nonce", %{"nonce" => "wrong"}},
        {"missing nonce", %{"nonce" => nil}},
        {"inappropriate authorized party", %{"azp" => "other-client"}},
        {"invalid email verification type", %{"email_verified" => "true"}},
        {"empty subject", %{"sub" => ""}},
        {"invalid profile type", %{"given_name" => 123}}
      ] do
    test "rejects #{description}", c do
      assert {:error, :invalid_id_token} = validate(c, unquote(Macro.escape(changes)))
    end
  end

  test "unverified email stays false for Accounts eligibility, never auto-verified", c do
    assert {:ok, identity} = validate(c, %{"email_verified" => false})
    refute identity.email_verified
  end

  test "expiration and not-before are enforced by OIDCC", c do
    assert {:error, _} = validate(c, %{"exp" => DateTime.to_unix(c.now) - 60})
    assert {:error, _} = validate(c, %{"nbf" => DateTime.to_unix(c.now) + 86_400})
  end

  for {label, offset, expected} <- [
        {"before", -1, :ok},
        {"equal", 0, :error},
        {"after", 1, :error}
      ] do
    test "strict post-OIDCC expiration: injected now #{label} exp", c do
      token = sign(c.key, c.claims)
      # OIDCC uses the real wall clock; exp is safely in its future. Only the
      # Magnum clock moves, proving all three exact boundaries deterministically.
      assert {:ok, _} = Oidcc.Token.validate_id_token(token, c.context, c.nonce)
      now = DateTime.from_unix!(c.claims["exp"] + unquote(offset))
      result = Protocol.validate_id_token(token, c.nonce, c.config, c.context, now: now)
      assert elem(result, 0) == unquote(expected)
    end
  end

  test "only RS256, never unsigned or other advertised algorithms", c do
    assert {:error, _} =
             Protocol.validate_id_token(
               sign(c.key, c.claims, "RS512"),
               c.nonce,
               c.config,
               c.context
             )

    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(c.claims), padding: false)

    assert {:error, _} =
             Protocol.validate_id_token(
               header <> "." <> payload <> ".",
               c.nonce,
               c.config,
               c.context
             )
  end

  test "encrypted unsigned token is rejected by OIDCC 3.9 itself", c do
    provider = %{
      c.context.provider_configuration
      | id_token_encryption_alg_values_supported: ["RSA-OAEP-256"],
        id_token_encryption_enc_values_supported: ["A256GCM"]
    }

    context = %{c.context | provider_configuration: provider, jwks: c.key}

    {_, encrypted} =
      JOSE.JWE.block_encrypt(JOSE.JWK.to_public(c.key), Jason.encode!(c.claims), %{
        "alg" => "RSA-OAEP-256",
        "enc" => "A256GCM"
      })
      |> JOSE.JWE.compact()

    assert {:error, :signature_required} =
             Oidcc.Token.validate_id_token(encrypted, context, c.nonce)

    assert {:error, _} = Protocol.validate_id_token(encrypted, c.nonce, c.config, context)
  end

  test "authorization is code + S256 and exact snapshot callback", c do
    {:ok, attempt} = Authentication.create_login_transaction(c.config, now: c.now)
    assert {:ok, url} = Protocol.authorization_url(attempt, c.config, c.context)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["response_type"] == "code"
    assert query["code_challenge_method"] == "S256"

    assert query["code_challenge"] ==
             :crypto.hash(:sha256, attempt.transaction.pkce_verifier)
             |> Base.url_encode64(padding: false)

    assert query["state"] == Credential.reveal(attempt.state)
    assert query["nonce"] == attempt.transaction.nonce
    assert query["redirect_uri"] == c.config.callback_url
    assert query["scope"] == "openid profile email"
    provider = %{c.context.provider_configuration | code_challenge_methods_supported: ["plain"]}

    assert {:error, :incompatible_provider} =
             Protocol.authorization_url(attempt, c.config, %{
               c.context
               | provider_configuration: provider
             })
  end

  test "raw claims and malformed JWT cannot bypass validation", c do
    assert {:error, _} = Protocol.validate_id_token(c.claims, c.nonce, c.config, c.context)
    assert {:error, _} = Protocol.validate_id_token("malformed", c.nonce, c.config, c.context)

    assert {:error, _} =
             Protocol.validate_id_token(sign(c.key, c.claims), nil, c.config, c.context)
  end

  test "real code exchange uses default transport and never returns provider tokens", c do
    {:ok, attempt} = Authentication.create_login_transaction(c.config, now: c.now)

    {:ok, material} =
      Authentication.consume_login_transaction(
        Credential.reveal(attempt.state),
        Credential.reveal(attempt.browser_binding),
        now: c.now
      )

    parent = self()
    claims = %{c.claims | "nonce" => material.nonce}
    token = sign(c.key, claims)

    pid =
      start_supervised!(
        {Bandit,
         plug:
           {SchedulerApi.OidcTestProvider,
            fn conn ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              params = URI.decode_query(body)
              send(parent, {:exchange, params})

              response =
                Jason.encode!(%{
                  id_token: token,
                  access_token: "in-memory-test-only",
                  token_type: "Bearer"
                })

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, response)
            end},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    provider = %{
      c.context.provider_configuration
      | token_endpoint: "http://127.0.0.1:#{port}/token"
    }

    context = %{c.context | provider_configuration: provider}

    assert {:ok, %VerifiedIdentity{} = identity} =
             Protocol.exchange_code("test-code", material, c.config, context, now: c.now)

    assert identity.subject == claims["sub"]
    assert_receive {:exchange, params}
    assert params["grant_type"] == "authorization_code"
    assert params["code_verifier"] == material.pkce_verifier
    assert params["redirect_uri"] == c.config.callback_url
    assert params["code"] == "test-code"
    refute Map.has_key?(Map.from_struct(identity), :access_token)

    for offset <- [0, 1] do
      now = DateTime.from_unix!(claims["exp"] + offset)

      assert {:error, :invalid_id_token} =
               Protocol.exchange_code("test-code", material, c.config, context, now: now)
    end

    assert {:error, :invalid_login_transaction} =
             Authentication.consume_login_transaction(
               Credential.reveal(attempt.state),
               Credential.reveal(attempt.browser_binding),
               now: c.now
             )
  end

  test "failed provider exchange leaves the transaction consumed", c do
    {:ok, attempt} = Authentication.create_login_transaction(c.config, now: c.now)

    {:ok, material} =
      Authentication.consume_login_transaction(
        Credential.reveal(attempt.state),
        Credential.reveal(attempt.browser_binding),
        now: c.now
      )

    pid =
      start_supervised!(
        {Bandit,
         plug:
           {SchedulerApi.OidcTestProvider,
            fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))
            end},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    provider = %{
      c.context.provider_configuration
      | token_endpoint: "http://127.0.0.1:#{port}/token"
    }

    assert {:error, :invalid_oidc_response} =
             Protocol.exchange_code(
               "test-code",
               material,
               c.config,
               %{c.context | provider_configuration: provider},
               now: c.now
             )

    assert {:error, :invalid_login_transaction} =
             Authentication.consume_login_transaction(
               Credential.reveal(attempt.state),
               Credential.reveal(attempt.browser_binding),
               now: c.now
             )

    stored = Repo.get!(SchedulerApi.Authentication.LoginTransaction, attempt.transaction.id)
    assert is_nil(stored.nonce) and is_nil(stored.pkce_verifier)
  end

  test "upstream outage has a bounded provider-unavailable error", c do
    {:ok, attempt} = Authentication.create_login_transaction(c.config, now: c.now)

    {:ok, material} =
      Authentication.consume_login_transaction(
        Credential.reveal(attempt.state),
        Credential.reveal(attempt.browser_binding),
        now: c.now
      )

    pid =
      start_supervised!(
        {Bandit,
         plug:
           {SchedulerApi.OidcTestProvider,
            fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(503, ~s({"error":"unavailable"}))
            end},
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    provider = %{
      c.context.provider_configuration
      | token_endpoint: "http://127.0.0.1:#{port}/token"
    }

    assert {:error, :provider_unavailable} =
             Protocol.exchange_code(
               "test-code",
               material,
               c.config,
               %{c.context | provider_configuration: provider},
               now: c.now
             )

    for code <- [nil, %{}, "", String.duplicate("x", 4097)] do
      assert {:error, :invalid_oidc_response} =
               Protocol.exchange_code(code, material, c.config, c.context)
    end
  end

  defp validate(c, changes \\ %{}) do
    Protocol.validate_id_token(
      sign(c.key, Map.merge(c.claims, changes)),
      c.nonce,
      c.config,
      c.context,
      now: c.now
    )
  end
end
