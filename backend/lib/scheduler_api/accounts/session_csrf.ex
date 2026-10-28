defmodule SchedulerApi.Accounts.SessionCSRF do
  @moduledoc "Plug's masked CSRF tokens backed by WebSession, not a second browser session cookie."

  def new_state, do: with_state(nil, &Plug.CSRFProtection.dump_state/0)
  def masked_token(state), do: with_state(state, &Plug.CSRFProtection.get_csrf_token/0)

  def valid?(state, token),
    do: Plug.CSRFProtection.valid_state_and_csrf_token?(state, token)

  defp with_state(state, fun) do
    # Only relative, masked tokens are used; no host-signed tokens/key derivation.
    # Explicitly isolate Plug's process dictionary, including reused test processes.
    Plug.CSRFProtection.delete_csrf_token()
    Plug.CSRFProtection.load_state("", state)
    fun.()
  after
    Plug.CSRFProtection.delete_csrf_token()
    Process.delete(:plug_unmasked_csrf_token)
    Process.delete(:plug_csrf_token_per_host)
  end
end
