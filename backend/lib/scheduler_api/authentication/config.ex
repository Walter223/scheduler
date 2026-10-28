defmodule SchedulerApi.Authentication.Config do
  @moduledoc "Explicit server-owned provider configuration; never populated from HTTP input."
  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:issuer, :client_secret, :callback_url]
  defstruct [:issuer, :client_secret, :callback_url, client_id: "magnum-web", local_http: false]

  @local_issuer "http://auth.magnum.test:8080/realms/magnum"

  def new(options, environment) do
    config = struct!(__MODULE__, options)
    issuer = URI.parse(config.issuer)
    callback = URI.parse(config.callback_url)
    local = environment == :dev and config.issuer == @local_issuer

    if valid_url?(issuer) and valid_url?(callback) and
         (issuer.scheme == "https" or local) and
         (callback.scheme == "https" or
            (local and config.callback_url == "http://localhost:5173/auth/callback")) and
         config.client_id == "magnum-web" and
         is_binary(config.client_secret) and byte_size(config.client_secret) > 0 do
      {:ok, %{config | local_http: local}}
    else
      {:error, :invalid_provider_config}
    end
  rescue
    _ -> {:error, :invalid_provider_config}
  end

  defp valid_url?(uri),
    do:
      uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

  def current do
    case Application.get_env(:scheduler_api, :oidc) do
      %__MODULE__{} = config -> {:ok, config}
      _ -> {:error, :auth_disabled}
    end
  end

  def worker_options(%__MODULE__{} = config) do
    %{
      name: SchedulerApi.Authentication.ProviderWorker,
      issuer: config.issuer,
      backoff_type: :random_exponential,
      backoff_min: 1_000,
      backoff_max: 30_000,
      provider_configuration_opts: %{
        quirks: %{allow_unsafe_http: config.local_http},
        request_opts: %{timeout: 5_000}
      }
    }
  end
end
