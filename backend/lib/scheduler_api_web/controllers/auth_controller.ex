defmodule SchedulerApiWeb.AuthController do
  use SchedulerApiWeb, :controller
  alias SchedulerApi.Accounts
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.Authentication.{Browser, BrowserConfig, Credential}
  alias SchedulerApiWeb.BrowserSession

  plug :private_response
  plug BrowserSession
  plug SchedulerApiWeb.SessionCSRF when action in [:logout]

  def login(conn, _params) do
    case Browser.begin_login() do
      {:ok, attempt, url} ->
        conn
        |> BrowserSession.put_binding(Credential.reveal(attempt.browser_binding))
        |> redirect(external: url)

      _ ->
        failure(conn, "provider_unavailable")
    end
  end

  def callback(conn, params) do
    binding = conn.req_cookies[BrowserSession.binding_name()]
    previous = conn.req_cookies[BrowserSession.session_name()]
    conn = BrowserSession.clear_binding(conn)

    case Browser.complete_login(params, binding, previous) do
      {:ok, {_session, credential}} ->
        conn
        |> BrowserSession.put_session(SessionCredential.reveal(credential))
        |> redirect(external: BrowserConfig.current().origin <> "/admin")

      {:error, :ineligible_account} ->
        failure(conn, "account_unavailable")

      {:error, reason} when reason in [:provider_unavailable, :auth_disabled] ->
        failure(conn, "provider_unavailable")

      _ ->
        failure(conn, "login_failed")
    end
  end

  def me(conn, _params) do
    session = conn.assigns.magnum_session

    with false <- is_nil(session),
         {:ok, csrf} <- Accounts.session_csrf_token(session) do
      user = session.user

      json(conn, %{
        authenticated: true,
        user: %{
          id: user.id,
          email: user.email,
          first_name: user.first_name,
          last_name: user.last_name
        },
        csrf_token: csrf
      })
    else
      _ -> json(conn, %{authenticated: false, user: nil, csrf_token: nil})
    end
  end

  def logout(conn, _params) do
    case Accounts.revoke_session(conn.assigns.magnum_session, :logout) do
      {:ok, _} ->
        conn
        |> BrowserSession.clear_session()
        |> BrowserSession.clear_binding()
        |> json(%{ok: true})

      _ ->
        conn |> put_status(503) |> json(%{error: "session_unavailable"})
    end
  end

  defp failure(conn, reason) do
    conn = BrowserSession.clear_binding(conn)

    case BrowserConfig.current().origin do
      origin when is_binary(origin) ->
        redirect(conn, external: origin <> "/admin?auth_error=" <> reason)

      _ ->
        conn |> put_status(503) |> json(%{error: "authentication_unavailable"})
    end
  end

  defp private_response(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
  end
end
