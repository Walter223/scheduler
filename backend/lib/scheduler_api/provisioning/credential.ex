defmodule SchedulerApi.Provisioning.Credential do
  @moduledoc "Inspect-redacted provisioning capability; never a browser or Accounts session."
  @enforce_keys [:value]
  @derive {Inspect, only: []}
  defstruct [:value]
  @opaque t :: %__MODULE__{value: binary()}

  @doc false
  def generate,
    do: %__MODULE__{value: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}

  @doc false
  def digest(%__MODULE__{value: value}) when is_binary(value) and byte_size(value) == 43 do
    with {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(value, padding: false),
         ^value <- Base.url_encode64(bytes, padding: false) do
      {:ok, :crypto.hash(:sha256, value)}
    else
      _ -> {:error, :invalid_intent}
    end
  end

  def digest(_), do: {:error, :invalid_intent}
end
