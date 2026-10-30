defmodule SchedulerApiWeb.AdminJSONBody do
  @moduledoc "Bounded private JSON parsing after authentication/CSRF, outside request telemetry."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [:json], json_decoder: Jason, length: 64_000)
    )
  rescue
    _ in [
      Plug.Parsers.ParseError,
      Plug.Parsers.UnsupportedMediaTypeError,
      Plug.Parsers.RequestTooLargeError
    ] ->
      conn |> put_status(422) |> Phoenix.Controller.json(%{error: "invalid_input"}) |> halt()
  end
end
