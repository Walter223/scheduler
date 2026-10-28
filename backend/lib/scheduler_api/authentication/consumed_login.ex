defmodule SchedulerApi.Authentication.ConsumedLogin do
  @moduledoc "Transient exchange material returned only by atomic consumption. Never persist or log."
  @enforce_keys [:issuer, :client_id, :callback_url, :nonce, :pkce_verifier, :return_path]
  @derive {Inspect, only: []}
  defstruct [:issuer, :client_id, :callback_url, :nonce, :pkce_verifier, :return_path]
end
