defmodule SchedulerApi.Authentication.Credential do
  @moduledoc "Inspect-redacted protocol credentials. Never use as an Accounts session credential."
  @enforce_keys [:value]
  @derive {Inspect, only: []}
  defstruct [:value]

  def generate,
    do: %__MODULE__{value: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}

  def reveal(%__MODULE__{value: value}), do: value

  def hash(value) when is_binary(value) and byte_size(value) == 43 do
    with {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(value, padding: false),
         ^value <- Base.url_encode64(bytes, padding: false) do
      {:ok, :crypto.hash(:sha256, value)}
    else
      _ -> {:error, :invalid_login_transaction}
    end
  end

  def hash(_), do: {:error, :invalid_login_transaction}
end
