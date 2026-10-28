defmodule SchedulerApi.OidcTestProvider do
  @moduledoc "Test-only local HTTP endpoint; exercises OIDCC's unchanged default transport."
  def init(handler), do: handler
  def call(conn, handler), do: handler.(conn)
end
