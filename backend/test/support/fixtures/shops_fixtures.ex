defmodule SchedulerApi.ShopsFixtures do
  alias SchedulerApi.{Catalog, Organizations, Repo}
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.Catalog.{Service, VehicleSize}

  def shop_fixture(attrs \\ %{}) do
    {business_id, attrs} = Map.pop(attrs, :business_id, Organizations.default_business!().id)

    attrs =
      Map.merge(
        %{
          name: "Other Shop",
          slug: "shop-#{System.unique_integer([:positive])}",
          timezone: "America/Denver"
        },
        attrs
      )

    %Shop{business_id: business_id} |> Shop.changeset(attrs) |> Repo.insert!()
  end

  def shop_price_fixture(price) do
    shop = shop_fixture(%{business_id: price.business_id})

    {:ok, other_price} =
      Catalog.create_service_price(shop, %{
        service_id: price.service_id,
        vehicle_size_id: price.vehicle_size_id,
        price_cents: 19999,
        duration_minutes: 120
      })

    %{shop: shop, price: other_price}
  end

  def other_business_price_fixture do
    business =
      %Business{}
      |> Business.changeset(%{
        name: "Other business",
        slug: "business-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    shop = shop_fixture(%{business_id: business.id})

    service =
      %Service{business_id: business.id}
      |> Service.changeset(%{name: "Other service", description: "Other business"})
      |> Repo.insert!()

    size =
      %VehicleSize{business_id: business.id}
      |> VehicleSize.changeset(%{name: "Small", sort_order: 1})
      |> Repo.insert!()

    {:ok, price} =
      Catalog.create_service_price(shop, %{
        service_id: service.id,
        vehicle_size_id: size.id,
        price_cents: 5000,
        duration_minutes: 60
      })

    %{shop: shop, price: price}
  end
end
