defmodule SchedulerApiWeb.ServiceJSON do
  @moduledoc """
  This module defines the JSON rendering for services.
  """
  def index(%{services: services}) do
    Enum.map(services, &data/1)
  end

  defp data(service) do
    %{
      id: service.id,
      name: service.name,
      description: service.description,
      prices:
        Enum.map(service.service_prices, fn price ->
          %{
            price_cents: price.price_cents,
            duration_minutes: price.duration_minutes,
            vehicle_size: price.vehicle_size.name,
            vehicle_size_id: price.vehicle_size.id
          }
        end)
    }
  end
end
