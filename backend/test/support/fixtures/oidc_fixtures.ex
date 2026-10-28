defmodule SchedulerApi.OidcFixtures do
  @moduledoc "Ephemeral, test-only signing keys and provider metadata. No Keycloak dependency."
  alias SchedulerApi.Authentication.{Config, Credential}

  def config do
    {:ok, config} =
      Config.new(
        [
          issuer: "https://identity.example.invalid/realms/magnum",
          client_secret: "test-only-confidential-client",
          callback_url: "https://app.example.invalid/auth/callback"
        ],
        :test
      )

    config
  end

  def context(key, config \\ config()) do
    provider = %Oidcc.ProviderConfiguration{
      issuer: config.issuer,
      authorization_endpoint: config.issuer <> "/protocol/openid-connect/auth",
      token_endpoint: config.issuer <> "/protocol/openid-connect/token",
      jwks_uri: config.issuer <> "/protocol/openid-connect/certs",
      scopes_supported: ["openid", "profile", "email"],
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      subject_types_supported: [:public],
      id_token_signing_alg_values_supported: ["RS256", "RS512", "none"],
      code_challenge_methods_supported: ["S256", "plain"]
    }

    Oidcc.ClientContext.from_manual(
      provider,
      JOSE.JWK.to_public(key),
      config.client_id,
      config.client_secret
    )
  end

  def claims(config, nonce, now) do
    %{
      "iss" => config.issuer,
      "sub" => "opaque|subject/not-a-uuid",
      "aud" => config.client_id,
      "iat" => DateTime.to_unix(now) - 60,
      "exp" => DateTime.to_unix(now) + 86_400,
      "nonce" => nonce,
      "email" => "staff@example.invalid",
      "email_verified" => true,
      "given_name" => "Example",
      "family_name" => "Staff"
    }
  end

  def nonce, do: Credential.generate() |> Credential.reveal()

  def sign(key, claims, algorithm \\ "RS256") do
    {_, token} = JOSE.JWT.sign(key, %{"alg" => algorithm}, claims) |> JOSE.JWS.compact()
    token
  end
end
