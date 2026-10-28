defmodule SchedulerApi.Authentication.Provider do
  @moduledoc "Optional discovery worker. Network failures retry inside OIDCC, not the app supervisor."
  alias SchedulerApi.Authentication.Config

  def children do
    case Config.current() do
      {:ok, config} -> [{Oidcc.ProviderConfiguration.Worker, Config.worker_options(config)}]
      {:error, :auth_disabled} -> []
    end
  end

  def context do
    with {:ok, config} <- Config.current(),
         {:ok, context} <-
           Oidcc.ClientContext.from_configuration_worker(
             SchedulerApi.Authentication.ProviderWorker,
             config.client_id,
             config.client_secret
           ) do
      {:ok, config, context}
    else
      {:error, :auth_disabled} = error -> error
      _ -> {:error, :provider_unavailable}
    end
  catch
    :exit, _ -> {:error, :provider_unavailable}
  end
end
