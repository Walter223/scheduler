defmodule SchedulerApiWeb.DashboardController do
  use SchedulerApiWeb, :controller

  def show(conn, _) do
    with true <- Enum.all?(Map.keys(conn.query_params), &(&1 == "shop_id")),
         {:ok, business} <- id(conn.path_params["business_id"]),
         {:ok, shop} <- shop(conn.query_params["shop_id"]),
         {:ok, data} <-
           SchedulerApi.Appointments.Dashboard.read(
             conn.assigns.magnum_session.user,
             business,
             shop
           ) do
      json(conn, %{data: data})
    else
      {:error, :forbidden} -> conn |> put_status(403) |> json(%{error: "forbidden"})
      _ -> conn |> put_status(422) |> json(%{error: "invalid_input"})
    end
  end

  defp shop(nil), do: {:ok, nil}
  defp shop(value), do: id(value)

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> {:error, :invalid_input}
    end
  end

  defp id(_), do: {:error, :invalid_input}
end
