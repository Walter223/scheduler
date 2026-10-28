defmodule SchedulerApi.Accounts.SessionCredential do
  @moduledoc """
  Inspect-redacted, one-time delivery of a web-session credential.
  Call `reveal/1` only at the eventual credential delivery boundary. Never log
  the revealed string. There is no configurable production random generator.
  """
  @enforce_keys [:value]
  @derive {Inspect, only: []}
  defstruct [:value]
  @opaque t :: %__MODULE__{value: binary()}

  @doc false
  def generate do
    %__MODULE__{value: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
  end

  def reveal(%__MODULE__{value: value}), do: value

  @doc false
  def hash_presented(token) when is_binary(token) and byte_size(token) == 43 do
    with {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(token, padding: false),
         ^token <- Base.url_encode64(bytes, padding: false) do
      {:ok, :crypto.hash(:sha256, token)}
    else
      _ -> {:error, :invalid_session}
    end
  end

  def hash_presented(_), do: {:error, :invalid_session}
end
