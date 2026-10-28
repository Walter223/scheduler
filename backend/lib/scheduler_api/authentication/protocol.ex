defmodule SchedulerApi.Authentication.Protocol do
  @moduledoc """
  Internal OIDCC boundary. Crypto/protocol validation precedes strict Magnum
  checks and VerifiedIdentity construction. Tokens are never persisted/returned.
  Configuration/context are trusted server values, never HTTP params.
  """
  alias SchedulerApi.Accounts.VerifiedIdentity
  alias SchedulerApi.Authentication
  alias SchedulerApi.Authentication.{Config, ConsumedLogin, Credential, LoginAttempt}

  def authorization_url(%LoginAttempt{} = attempt, %Config{} = config, context) do
    transaction = attempt.transaction

    with :ok <- matches?(transaction, config),
         {:ok, context} <- restrict(context, config),
         true <- s256?(context) do
      case Oidcc.Authorization.create_redirect_url(context, %{
             redirect_uri: transaction.callback_url,
             scopes: ["openid", "profile", "email"],
             state: Credential.reveal(attempt.state),
             nonce: transaction.nonce,
             pkce_verifier: transaction.pkce_verifier,
             require_pkce: true,
             preferred_auth_methods: [:client_secret_basic],
             request_opts: %{timeout: 5_000},
             response_mode: "query"
           }) do
        {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
        _ -> {:error, :provider_unavailable}
      end
    else
      false -> {:error, :incompatible_provider}
      error -> error
    end
  end

  @doc "Consumption must already have committed. No DB transaction spans this exchange."
  def exchange_code(code, login, config, context, opts \\ [])

  def exchange_code(code, %ConsumedLogin{} = login, %Config{} = config, context, opts)
      when is_binary(code) and byte_size(code) in 1..4096 do
    with :ok <- matches?(login, config),
         {:ok, context} <- restrict(context, config),
         true <- s256?(context),
         true <- Application.get_env(:oidcc, :max_clock_skew, 0) == 0,
         {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} <-
           Oidcc.Token.retrieve(code, context, %{
             redirect_uri: login.callback_url,
             nonce: login.nonce,
             pkce_verifier: login.pkce_verifier,
             require_pkce: true,
             preferred_auth_methods: [:client_secret_basic],
             trusted_audiences: [],
             validate_azp: :client_id,
             request_opts: %{timeout: 5_000}
           }) do
      verified_identity(claims, config, opts)
    else
      {:error, {:failed_connect, _}} -> {:error, :provider_unavailable}
      {:error, :timeout} -> {:error, :provider_unavailable}
      {:error, {:http_error, status, _}} when status >= 500 -> {:error, :provider_unavailable}
      _ -> {:error, :invalid_oidc_response}
    end
  rescue
    _ -> {:error, :invalid_oidc_response}
  catch
    :exit, _ -> {:error, :provider_unavailable}
  end

  def exchange_code(_, _, _, _, _), do: {:error, :invalid_oidc_response}

  @doc "Real OIDCC validation; internal API, not a claims-map constructor."
  def validate_id_token(token, nonce, %Config{} = config, context, opts \\ []) do
    with true <- is_binary(token) and byte_size(token) in 1..65_536,
         true <- is_binary(nonce) and byte_size(nonce) == 43,
         true <- Application.get_env(:oidcc, :max_clock_skew, 0) == 0,
         {:ok, context} <- restrict(context, config),
         {:ok, claims} <-
           Oidcc.Token.validate_id_token(token, context, %{
             nonce: nonce,
             trusted_audiences: [],
             validate_azp: :client_id
           }) do
      verified_identity(claims, config, opts)
    else
      _ -> {:error, :invalid_id_token}
    end
  rescue
    # Library errors can contain tokens/claims; never expose or log those terms.
    _ -> {:error, :invalid_id_token}
  end

  defp restrict(%Oidcc.ClientContext{} = context, config) do
    provider = context.provider_configuration

    if context.client_id == config.client_id and provider.issuer == config.issuer and
         provider.issuer_regex == :undefined and
         "RS256" in provider.id_token_signing_alg_values_supported do
      provider = %{
        provider
        | id_token_signing_alg_values_supported: ["RS256"],
          id_token_encryption_alg_values_supported: [],
          id_token_encryption_enc_values_supported: []
      }

      {:ok, %{context | provider_configuration: provider}}
    else
      {:error, :incompatible_provider}
    end
  end

  defp s256?(context),
    do:
      is_list(context.provider_configuration.code_challenge_methods_supported) and
        "S256" in context.provider_configuration.code_challenge_methods_supported

  defp matches?(transaction, config) do
    if transaction.issuer == config.issuer and transaction.client_id == config.client_id and
         transaction.callback_url == config.callback_url,
       do: :ok,
       else: {:error, :provider_configuration_changed}
  end

  # Private: called only AFTER successful OIDCC validation, never from HTTP claims.
  defp verified_identity(claims, config, opts) do
    with {:ok, now} <- Authentication.now(opts),
         exp when is_integer(exp) <- claims["exp"],
         true <- DateTime.to_unix(now) < exp,
         true <- claims["iss"] == config.issuer,
         true <- valid_text?(claims["sub"], 1024),
         true <- valid_text?(claims["email"], 320),
         true <- is_boolean(claims["email_verified"]),
         true <- valid_name?(claims["given_name"]),
         true <- valid_name?(claims["family_name"]),
         {:ok, authenticated_at} <- auth_time(claims["auth_time"], now),
         iat when is_integer(iat) <- claims["iat"],
         true <- iat <= DateTime.to_unix(now),
         true <- valid_azp?(claims, config.client_id) do
      {:ok,
       %VerifiedIdentity{
         issuer: claims["iss"],
         subject: claims["sub"],
         email: claims["email"],
         email_verified: claims["email_verified"],
         first_name: claims["given_name"],
         last_name: claims["family_name"],
         authenticated_at: authenticated_at
       }}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  defp valid_text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= max and
        String.trim(value) != ""

  defp valid_name?(nil), do: true
  defp valid_name?(value), do: valid_text?(value, 255)
  defp auth_time(nil, _), do: {:ok, nil}

  defp auth_time(value, now) when is_integer(value) and value >= 0 do
    if value <= DateTime.to_unix(now),
      do: DateTime.from_unix(value),
      else: {:error, :invalid_auth_time}
  end

  defp auth_time(_, _), do: {:error, :invalid_auth_time}

  defp valid_azp?(%{"aud" => aud} = claims, client) when is_list(aud) and length(aud) > 1,
    do: claims["azp"] == client

  defp valid_azp?(claims, client), do: is_nil(claims["azp"]) or claims["azp"] == client
end
