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
    description:
      "Exterior wash, clay bar, and spray wax. Interior surface cleaning included and vacuuming."
  })

supreme =
  Repo.insert!(%Service{
    name: "Supreme Detail",
    description:
      "Exterior wash, clay bar, tire shine, 2-step polish, and hand wax. Interior surface cleaning, vacuum, shampooing, and choice of fragrance included."
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
  {basic, small, 5999, 60},
  {basic, medium, 8999, 90},
  {basic, large, 10_999, 120},
  {mid, small, 8999, 90},
  {mid, medium, 11_999, 120},
  {mid, large, 13_999, 150},
  {supreme, small, 12_999, 150},
  {supreme, medium, 15_999, 180},
  {supreme, large, 17_999, 230}
]

Enum.each(prices, fn {service, vehicle_size, price_cents, duration_minutes} ->
  Repo.insert!(%ServicePrice{
    service_id: service.id,
    vehicle_size_id: vehicle_size.id,
    price_cents: price_cents,
    duration_minutes: duration_minutes
  })
end)
