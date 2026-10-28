defmodule SchedulerApi.BrowserTestProvider do
  @moduledoc false
  def context, do: Process.get(:browser_test_provider, {:error, :provider_unavailable})
end
