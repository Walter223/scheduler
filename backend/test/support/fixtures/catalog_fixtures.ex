defmodule SchedulerApi.CatalogFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `SchedulerApi.Catalog` context.
  """

  @doc """
  Generate a service.
  """
  def service_fixture(attrs \\ %{}) do
    {:ok, service} =
      attrs
      |> Enum.into(%{
        description: "some  description",
        name: "some  name"
      })
      |> SchedulerApi.Catalog.create_service()

    service
  end

  @doc """
  Generate a vehicle_size.
  """
  def vehicle_size_fixture(attrs \\ %{}) do
    {:ok, vehicle_size} =
      attrs
      |> Enum.into(%{
        name: "some  name",
        sort_order: 42
      })
      |> SchedulerApi.Catalog.create_vehicle_size()

    vehicle_size
  end

  @doc """
  Generate a service_price.
  """
  def service_price_fixture(attrs \\ %{}) do
    {:ok, service_price} =
      attrs
      |> Enum.into(%{
        price_cents: 42
      })
      |> SchedulerApi.Catalog.create_service_price()

    service_price
  end
end
