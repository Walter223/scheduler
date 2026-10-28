defmodule SchedulerApi.Authentication.BrowserConfig do
  @moduledoc "Trusted application origin/cookie contract. Never inferred from request headers."
  def new(origin, environment) when is_binary(origin) do
    uri = URI.parse(origin)
    local = environment == :dev and origin == "http://localhost:5173"

    if URI.to_string(uri) == origin and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, ""] and
         (uri.scheme == "https" or local) do
      {:ok, %{origin: origin, secure: not local}}
    else
      {:error, :invalid_browser_config}
    end
  rescue
    _ -> {:error, :invalid_browser_config}
  end

  def new(_, _), do: {:error, :invalid_browser_config}
  def current, do: Application.fetch_env!(:scheduler_api, :browser_auth)
end
