defmodule SchedulerApiWeb.BrowserSession do
  @moduledoc "Opaque cookie adapter; PostgreSQL eligibility/revocation remain authoritative."
  import Plug.Conn, except: [clear_session: 1]
  alias SchedulerApi.Accounts
  alias SchedulerApi.Authentication.BrowserConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    token = conn.req_cookies[session_name()]

    case Accounts.get_session_by_token(token) do
      {:ok, session} ->
        assign(conn, :magnum_session, session)

      _ ->
        conn = if token, do: clear_session(conn), else: conn
        assign(conn, :magnum_session, nil)
    end
  end

  def session_name,
    do: if(secure?(), do: "__Host-magnum_session", else: "magnum_session_dev")

  def binding_name,
    do: if(secure?(), do: "__Host-magnum_login", else: "magnum_login_dev")

  def options, do: [http_only: true, secure: secure?(), same_site: "Lax", path: "/"]
  def put_session(conn, token), do: put_resp_cookie(conn, session_name(), token, options())
  def clear_session(conn), do: delete_resp_cookie(conn, session_name(), options())
  def clear_binding(conn), do: delete_resp_cookie(conn, binding_name(), options())

  def put_binding(conn, token),
    do: put_resp_cookie(conn, binding_name(), token, options() ++ [max_age: 600])

  defp secure?, do: BrowserConfig.current().secure
end
