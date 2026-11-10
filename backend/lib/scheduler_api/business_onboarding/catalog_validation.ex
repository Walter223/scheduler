defmodule SchedulerApi.BusinessOnboarding.CatalogValidation do
  @moduledoc false
  @modes ~w(in_shop mobile both)

  # Legacy schema-v1 proposals remain readable/saveable. The editor explicitly
  # upgrades them before using the richer catalog format; no stored data is rewritten.
  def valid?(%{"catalog" => c, "services" => services} = p) do
    exact?(c, ~w(version currency vehicle_categories)) and c["version"] == 1 and
      c["currency"] == "USD" and collection?(c["vehicle_categories"], 20, &category?/1) and
      unique?(c["vehicle_categories"], "key") and unique_names?(c["vehicle_categories"]) and
      collection?(services, 100, &service?(&1, c["vehicle_categories"], p)) and
      unique?(services, "key") and unique_names?(services)
  end

  def valid?(%{"services" => services}),
    do: collection?(services, 100, &legacy?/1) and unique_names?(services)

  def valid?(_), do: false

  def complete?(%{"catalog" => _} = p), do: p["services"] != [] and valid?(p)
  def complete?(_), do: false

  defp service?(s, categories, p) do
    exact?(
      s,
      ~w(version key name description duration_minutes status delivery_mode location_keys prices overrides)
    ) and
      s["version"] == 2 and key?(s["key"]) and text?(s["name"], 255) and
      description?(s["description"]) and duration?(s["duration_minutes"]) and
      s["status"] in ~w(active planned) and s["delivery_mode"] in @modes and
      references?(s["location_keys"], Enum.map(p["locations"], & &1["key"])) and
      s["location_keys"] != [] and categories != [] and
      prices?(s["prices"], categories, true) and
      collection?(s["overrides"], 20, &override?(&1, s, categories)) and
      unique?(s["overrides"], "location_key") and
      Enum.all?(s["location_keys"], fn key ->
        location = Enum.find(p["locations"], &(&1["key"] == key))
        shop_mode = location["operating_model"] || p["defaults"]["operating_model"]
        override = Enum.find(s["overrides"], %{}, &(&1["location_key"] == key))
        mode = override["delivery_mode"] || s["delivery_mode"]
        shop_mode == "both" or mode == shop_mode
      end)
  end

  defp override?(o, s, categories) do
    allowed = ~w(location_key prices duration_minutes delivery_mode status)

    keys?(o, allowed, ~w(location_key prices)) and o["location_key"] in s["location_keys"] and
      prices?(o["prices"], categories, false) and
      (not Map.has_key?(o, "duration_minutes") or duration?(o["duration_minutes"])) and
      (not Map.has_key?(o, "delivery_mode") or o["delivery_mode"] in @modes) and
      (not Map.has_key?(o, "status") or o["status"] in ~w(active planned))
  end

  defp prices?(prices, categories, complete) do
    keys = Enum.map(categories, & &1["key"])

    collection?(prices, 20, fn price ->
      exact?(price, ~w(category_key price_cents)) and price["category_key"] in keys and
        integer?(price["price_cents"], 1, 100_000_000)
    end) and unique?(prices, "category_key") and
      (not complete or Enum.sort(Enum.map(prices, & &1["category_key"])) == Enum.sort(keys))
  end

  defp category?(c), do: exact?(c, ~w(key name)) and key?(c["key"]) and text?(c["name"], 255)

  defp legacy?(s),
    do:
      exact?(s, ~w(name duration_minutes price_cents)) and text?(s["name"], 255) and
        duration?(s["duration_minutes"]) and integer?(s["price_cents"], 1, 100_000_000)

  defp duration?(v), do: integer?(v, 1, 1440)
  defp integer?(v, min, max), do: is_integer(v) and v >= min and v <= max
  defp key?(v), do: text?(v, 64) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, v)

  defp description?(v),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..2000 and
        String.trim(v) == v and not Regex.match?(~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/, v)

  defp text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and String.trim(v) == v and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, v)

  defp keys?(m, allowed, required),
    do:
      is_map(m) and Enum.all?(Map.keys(m), &(&1 in allowed)) and
        Enum.all?(required, &Map.has_key?(m, &1))

  defp exact?(m, keys), do: keys?(m, keys, keys)

  defp collection?(list, max, fun),
    do: is_list(list) and length(list) <= max and Enum.all?(list, fun)

  defp unique?(list, key), do: length(list) == length(Enum.uniq_by(list, & &1[key]))

  defp unique_names?(list),
    do: length(list) == length(Enum.uniq_by(list, &String.downcase(&1["name"])))

  defp references?(list, keys),
    do: collection?(list, 20, &(&1 in keys)) and length(list) == length(Enum.uniq(list))
end
