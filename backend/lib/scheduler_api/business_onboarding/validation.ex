defmodule SchedulerApi.BusinessOnboarding.Validation do
  @moduledoc false
  import Ecto.Query
  alias SchedulerApi.Repo
  @sections ~w(locations defaults employees services branding)
  @models ~w(in_shop mobile both)
  @mobile ~w(service_areas dispatch_source dispatch_location_key travel_buffer_minutes)
  def empty, do: Map.new(@sections, &{&1, if(&1 in ~w(defaults branding), do: %{}, else: [])})

  def valid?(p, business_id) when is_map(p) do
    keys?(p, @sections, @sections) and
      list?(p["locations"], 20, &location?(&1, business_id)) and
      unique?(p["locations"], "key") and unique_existing?(p["locations"]) and
      defaults?(p["defaults"]) and
      Enum.all?(effective_locations(p), fn l ->
        zone?(l["timezone"]) and l["operating_model"] in @models
      end) and
      references?(p) and
      list?(p["employees"], 100, &employee?(&1, p["locations"])) and
      list?(p["services"], 100, &service?/1) and branding?(p["branding"])
  end

  def valid?(_, _), do: false

  # Defaults are resolved for presentation/validation only. Arrays replace; mobile
  # objects merge by allowlisted field. No scheduling/domain application occurs.
  def effective_locations(p) do
    Enum.map(p["locations"], fn location ->
      merged = Map.merge(p["defaults"], location)
      inherited_mobile = p["defaults"]["mobile"] || %{}
      local_mobile = location["mobile"] || %{}

      inherited_mobile =
        if local_mobile["dispatch_source"] == "this_location",
          do: Map.delete(inherited_mobile, "dispatch_location_key"),
          else: inherited_mobile

      mobile = Map.merge(inherited_mobile, local_mobile)
      Map.put(merged, "mobile", mobile)
    end)
  end

  def locations_complete?(p) do
    Enum.all?(effective_locations(p), fn l ->
      text?(l["address"], 1000) and
        (l["operating_model"] == "in_shop" or
           (is_list(l["mobile"]["service_areas"]) and l["mobile"]["service_areas"] != [] and
              l["mobile"]["dispatch_source"] in ~w(this_location location_key) and
              integer?(l["mobile"]["travel_buffer_minutes"], 0, 240)))
    end)
  end

  defp location?(l, business_id) do
    keys?(
      l,
      ~w(key existing_shop_id name address timezone operating_model mobile),
      ~w(key name)
    ) and
      key?(l["key"]) and text?(l["name"], 255) and optional_text?(l, "address", 1000) and
      (not Map.has_key?(l, "timezone") or zone?(l["timezone"])) and
      (not Map.has_key?(l, "operating_model") or l["operating_model"] in @models) and
      (not Map.has_key?(l, "mobile") or mobile?(l["mobile"])) and
      (not Map.has_key?(l, "existing_shop_id") or
         (is_integer(l["existing_shop_id"]) and
            Repo.exists?(
              from s in SchedulerApi.Organizations.Shop,
                where:
                  s.id == ^l["existing_shop_id"] and s.business_id == ^business_id and
                    s.status == :active
            )))
  end

  defp defaults?(d),
    do:
      keys?(d, ~w(timezone operating_model mobile), []) and
        (not Map.has_key?(d, "timezone") or zone?(d["timezone"])) and
        (not Map.has_key?(d, "operating_model") or d["operating_model"] in @models) and
        (not Map.has_key?(d, "mobile") or mobile?(d["mobile"]))

  defp mobile?(m),
    do:
      keys?(m, @mobile, []) and
        (not Map.has_key?(m, "service_areas") or list?(m["service_areas"], 20, &text?(&1, 200))) and
        (not Map.has_key?(m, "dispatch_source") or
           m["dispatch_source"] in ~w(this_location location_key)) and
        (not Map.has_key?(m, "dispatch_location_key") or key?(m["dispatch_location_key"])) and
        (not Map.has_key?(m, "travel_buffer_minutes") or
           integer?(m["travel_buffer_minutes"], 0, 240))

  defp references?(p) do
    keys = Enum.map(p["locations"], & &1["key"])

    Enum.all?(
      [p["defaults"]["mobile"] || %{} | Enum.map(effective_locations(p), &(&1["mobile"] || %{}))],
      fn m ->
        case m["dispatch_source"] do
          "location_key" -> m["dispatch_location_key"] in keys
          _ -> not Map.has_key?(m, "dispatch_location_key")
        end
      end
    )
  end

  defp employee?(e, locations),
    do:
      keys?(e, ~w(name email intended_role location_keys), ~w(name)) and
        text?(e["name"], 255) and optional_text?(e, "email", 255) and
        (not Map.has_key?(e, "intended_role") or
           e["intended_role"] in ~w(employee shop_manager business_manager)) and
        (not Map.has_key?(e, "location_keys") or
           list?(e["location_keys"], 20, &(&1 in Enum.map(locations, fn l -> l["key"] end))))

  defp service?(s),
    do:
      keys?(s, ~w(name duration_minutes price_cents), ~w(name duration_minutes price_cents)) and
        text?(s["name"], 255) and integer?(s["duration_minutes"], 1, 1440) and
        integer?(s["price_cents"], 0, 100_000_000)

  defp branding?(b),
    do:
      keys?(b, ~w(display_name primary_color), []) and optional_text?(b, "display_name", 255) and
        (not Map.has_key?(b, "primary_color") or
           (is_binary(b["primary_color"]) and
              Regex.match?(~r/^#[0-9a-fA-F]{6}$/, b["primary_color"])))

  defp keys?(m, allowed, required),
    do:
      is_map(m) and Enum.all?(Map.keys(m), &(&1 in allowed)) and
        Enum.all?(required, &Map.has_key?(m, &1))

  defp list?(l, max, fun), do: is_list(l) and length(l) <= max and Enum.all?(l, fun)

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) <= max and String.valid?(s) and String.trim(s) != "" and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, s)

  defp optional_text?(m, k, max), do: not Map.has_key?(m, k) or text?(m[k], max)
  defp key?(s), do: text?(s, 64) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, s)

  defp zone?(z),
    do: text?(z, 255) and Repo.exists?(from t in "pg_timezone_names", where: t.name == ^z)

  defp integer?(n, min, max), do: is_integer(n) and n >= min and n <= max
  defp unique?(l, k), do: length(l) == length(Enum.uniq_by(l, & &1[k]))

  defp unique_existing?(l) do
    ids = Enum.filter(Enum.map(l, & &1["existing_shop_id"]), & &1)
    length(ids) == length(Enum.uniq(ids))
  end
end
