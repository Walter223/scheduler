defmodule SchedulerApiWeb.SignupController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Authentication.{Browser, BrowserConfig, Credential}
  alias SchedulerApi.Provisioning.Onboarding
  alias SchedulerApiWeb.{BrowserSession, SessionCSRF, AdminJSONBody}
  plug :private_boundary
  plug :origin_and_budget when action in [:login, :create]
  plug AdminJSONBody when action in [:login, :create]

  def cookie_name,
    do:
      if(BrowserConfig.current().secure,
        do: "__Host-magnum_onboarding",
        else: "magnum_onboarding_dev"
      )

  def binding_name,
    do:
      if(BrowserConfig.current().secure,
        do: "__Host-magnum_onboarding_binding",
        else: "magnum_onboarding_binding_dev"
      )

  def deliver(conn, token, binding) do
    conn
    |> put_resp_cookie(
      cookie_name(),
      Credential.reveal(token),
      BrowserSession.options() ++ [max_age: 600]
    )
    |> put_resp_cookie(binding_name(), binding, BrowserSession.options() ++ [max_age: 600])
  end

  def login(conn, params) do
    if params not in [%{}, %{"mode" => "register"}] do
      fail(conn, :invalid_input)
    else
      case Browser.begin_login(:signup, params == %{"mode" => "register"}) do
        {:ok, attempt, url} ->
          conn = BrowserSession.put_binding(conn, Credential.reveal(attempt.browser_binding))

          if "application/json" in get_req_header(conn, "accept"),
            do: json(conn, %{redirect_to: url}),
            else: redirect(conn, external: url)

        _ ->
          fail(conn, :operation_unavailable)
      end
    end
  end

  def timezones(conn, params) do
    if params == %{} do
      case Onboarding.timezones() do
        {:ok, zones} -> json(conn, %{timezones: zones})
        _ -> fail(conn, :operation_unavailable)
      end
    else
      fail(conn, :invalid_input)
    end
  end

  def show(conn, params) do
    if params != %{} do
      fail(conn, :invalid_input)
    else
      case Onboarding.status(conn.req_cookies[cookie_name()], conn.req_cookies[binding_name()]) do
        {:ok, result} -> json(conn, result)
        {:error, error} -> fail(conn, error)
      end
    end
  end

  def create(conn, params) do
    with %{"business" => b, "shop" => s} when map_size(params) == 2 <- params,
         %{"name" => bn, "slug" => bs} when map_size(b) == 2 <- b,
         %{"name" => sn, "slug" => ss, "timezone" => tz} when map_size(s) == 3 <- s,
         {:ok, csrf} <- csrf_header(conn),
         {:ok, result} <-
           Onboarding.complete(
             conn.req_cookies[cookie_name()],
             conn.req_cookies[binding_name()],
             csrf,
             %{business: %{name: bn, slug: bs}, shop: %{name: sn, slug: ss, timezone: tz}}
           ) do
      # Retain the expiring proof cookie for safe identical retries. No session is issued.
      json(conn, %{data: Map.take(result, ["business_id", "shop_id", "business_name"])})
    else
      {:error, reason} -> fail(conn, reason)
      _ -> fail(conn, :invalid_input)
    end
  end

  defp csrf_header(conn) do
    case get_req_header(conn, "x-csrf-token") do
      [csrf] -> {:ok, csrf}
      _ -> {:error, :invalid_csrf}
    end
  end

  defp private_boundary(conn, _) do
    conn
    |> fetch_cookies()
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp origin_and_budget(conn, _) do
    cond do
      not SessionCSRF.acceptable_origin?(conn) ->
        conn |> fail(:invalid_origin) |> halt()

      conn.query_string != "" ->
        conn |> fail(:invalid_input) |> halt()

      true ->
        case Onboarding.attempt(conn.remote_ip |> :inet.ntoa() |> to_string()) do
          {:ok, _} -> conn
          {:error, e} -> conn |> fail(e) |> halt()
        end
    end
  end

  defp fail(conn, reason) do
    {status, error} =
      case reason do
        :invalid_origin -> {403, "forbidden"}
        :invalid_csrf -> {403, "forbidden"}
        :invalid_input -> {422, "invalid_input"}
        :slug_unavailable -> {409, "signup_conflict"}
        :replayed_proof -> {409, "signup_conflict"}
        :rate_limited -> {429, "try_later"}
        :operation_unavailable -> {503, "operation_unavailable"}
        _ -> {403, "signup_unavailable"}
      end

    conn |> put_status(status) |> json(%{error: error})
  end
end
