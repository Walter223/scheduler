defmodule SchedulerApiWeb.SessionCSRF do
  @moduledoc "CSRF boundary for authenticated mutations only; public booking is independent."
  import Plug.Conn
  alias SchedulerApi.Accounts.SessionCSRF
  alias SchedulerApi.Authentication.BrowserConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    session = conn.assigns[:magnum_session]

    cond do
      is_nil(session) -> reject(conn, 401, "authentication_required")
      not acceptable_origin?(conn) -> reject(conn, 403, "invalid_origin")
      not valid_token?(conn, session.csrf_state) -> reject(conn, 403, "invalid_csrf_token")
      true -> conn
    end
  end

  def acceptable_origin?(conn) do
    expected = BrowserConfig.current().origin

    case get_req_header(conn, "origin") do
      [^expected] when is_binary(expected) ->
        true

      [] ->
        case get_req_header(conn, "referer") do
          [referer] -> acceptable_referer?(referer, expected)
          _ -> false
        end

      _ ->
        false
    end
  end

  # Compare the literal authority boundary, not URI.parse's permissive port
  # normalization (which can turn :5173.evil into :5173).
  defp acceptable_referer?(value, expected) when is_binary(expected) do
    (value == expected or String.starts_with?(value, expected <> "/")) and
      not Regex.match?(~r/[\\\\\x00-\x20\x7f]/, value)
  end

  defp acceptable_referer?(_, _), do: false

  defp valid_token?(conn, state) do
    case get_req_header(conn, "x-csrf-token") do
      [token] when byte_size(token) <= 128 -> SessionCSRF.valid?(state, token)
      _ -> false
    end
  end

  defp reject(conn, status, error) do
    conn |> put_status(status) |> Phoenix.Controller.json(%{error: error}) |> halt()
  end
end
