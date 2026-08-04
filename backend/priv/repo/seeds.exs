alias SchedulerApi.Repo
alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}

basic =
  Repo.insert!(%Service{
    name: "Basic Detail",
    description: "A simple wash, dry, and basic spray detail of the exterior. No interior detail."
  })

mid =
  Repo.insert!(%Service{
    name: "Mid Detail",
    description: "Exterior wash, clay bar, and spray detail. Interior surface cleaning included."
  })

supreme =
  Repo.insert!(%Service{
    name: "Supreme Detail",
    description:
      "Exterior wash, clay bar, tire shine, and wax. Interior surface cleaning, shampooing, and choice of fragrance included."
  })

small =
  Repo.insert!(%VehicleSize{
    name: "Small",
    sort_order: 1
  })

medium =
  Repo.insert!(%VehicleSize{
    name: "Medium",
    sort_order: 2
  })

large =
  Repo.insert!(%VehicleSize{
    name: "Large",
    sort_order: 3
  })

prices = [
  {basic, small, 5999},
  {basic, medium, 8999},
  {basic, large, 10_999},
  {mid, small, 8999},
  {mid, medium, 11_999},
  {mid, large, 13_999},
  {supreme, small, 12_999},
  {supreme, medium, 15_999},
  {supreme, large, 17_999}
]

Enum.each(prices, fn {service, vehicle_size, price_cents} ->
  Repo.insert!(%ServicePrice{
    service_id: service.id,
    vehicle_size_id: vehicle_size.id,
    price_cents: price_cents
  })
end)
