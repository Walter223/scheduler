defmodule SchedulerApi.Authentication.LoginAttempt do
  @moduledoc "One-time delivery of state/binding and server transaction; not an authenticated session."
  @enforce_keys [:transaction, :state, :browser_binding]
  @derive {Inspect, only: []}
  defstruct [:transaction, :state, :browser_binding]
end
