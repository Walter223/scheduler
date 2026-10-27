alias SchedulerApi.{Repo, Organizations}
alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}

shop = Organizations.default_shop!()

get_or_insert = fn schema, keys, attrs ->
  Repo.get_by(schema, keys) || Repo.insert!(struct(schema, Map.merge(attrs, Map.new(keys))))
end

basic =
  get_or_insert.(Service, [business_id: shop.business_id, name: "Basic Detail"], %{
    description: "A simple wash, dry, and basic spray detail of the exterior. No interior detail."
  })

mid =
  get_or_insert.(Service, [business_id: shop.business_id, name: "Mid Detail"], %{
    description:
      "Exterior wash, clay bar, and spray wax. Interior surface cleaning included and vacuuming."
  })

supreme =
  get_or_insert.(Service, [business_id: shop.business_id, name: "Supreme Detail"], %{
    description:
      "Exterior wash, clay bar, tire shine, 2-step polish, and hand wax. Interior surface cleaning, vacuum, shampooing, and choice of fragrance included."
  })

small =
  get_or_insert.(VehicleSize, [business_id: shop.business_id, name: "Small"], %{sort_order: 1})

medium =
  get_or_insert.(VehicleSize, [business_id: shop.business_id, name: "Medium"], %{sort_order: 2})

large =
  get_or_insert.(VehicleSize, [business_id: shop.business_id, name: "Large"], %{sort_order: 3})

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
  get_or_insert.(
    ServicePrice,
    [shop_id: shop.id, service_id: service.id, vehicle_size_id: vehicle_size.id],
    %{
      business_id: shop.business_id,
      price_cents: price_cents,
      duration_minutes: duration_minutes
    }
  )
end)
