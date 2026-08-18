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
            vehicle_size: price.vehicle_size.name
          }
        end)
    }
  end
end
