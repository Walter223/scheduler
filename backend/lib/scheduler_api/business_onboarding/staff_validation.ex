defmodule SchedulerApi.BusinessOnboarding.StaffValidation do
  @moduledoc false
  @classifications ~w(detailer shop_manager business_manager business_owner)
  def valid?(staff, locations) when is_list(staff) and length(staff) <= 100 do
    keys = Enum.map(locations, & &1["key"])

    Enum.all?(staff, &person?(&1, keys)) and
      length(staff) == length(Enum.uniq_by(staff, & &1["key"])) and
      length(staff) == length(Enum.uniq_by(staff, &String.downcase(&1["email"])))
  end

  def valid?(_, _), do: false

  defp person?(p, locations) do
    fields = ~w(version key name email classification location_keys responsibilities access_roles)

    exact?(p, fields) and p["version"] == 2 and key?(p["key"]) and text?(p["name"], 255) and
      email?(p["email"]) and p["classification"] in @classifications and
      subset?(p["location_keys"], locations) and
      exact?(p["responsibilities"], ~w(business_management shop_management_keys)) and
      is_boolean(p["responsibilities"]["business_management"]) and
      subset?(p["responsibilities"]["shop_management_keys"], p["location_keys"]) and
      is_list(p["access_roles"]) and length(p["access_roles"]) <= 3 and
      Enum.all?(p["access_roles"], &role?(&1, p["location_keys"])) and
      length(p["access_roles"]) == length(Enum.uniq_by(p["access_roles"], & &1["role"]))
  end

  defp role?(r, assignments) do
    exact?(r, ~w(role location_keys)) and
      case r["role"] do
        "business_manager" ->
          r["location_keys"] == []

        role when role in ~w(shop_manager employee) ->
          subset?(r["location_keys"], assignments) and r["location_keys"] != []

        _ ->
          false
      end
  end

  defp exact?(m, keys), do: is_map(m) and Enum.sort(Map.keys(m)) == Enum.sort(keys)

  defp subset?(values, allowed),
    do:
      is_list(values) and length(values) <= 20 and length(values) == length(Enum.uniq(values)) and
        Enum.all?(values, &(&1 in allowed))

  defp text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and String.trim(v) == v and
        v != "" and not Regex.match?(~r/[\x00-\x1f\x7f]/, v)

  defp key?(v), do: text?(v, 64) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, v)

  defp email?(v) do
    if text?(v, 254) do
      case String.split(v, "@") do
        [local, domain] ->
          labels = String.split(domain, ".")

          allowed =
            ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~"

          byte_size(local) in 1..64 and not String.starts_with?(local, ".") and
            not String.ends_with?(local, ".") and not String.contains?(local, "..") and
            Enum.all?(String.to_charlist(local), &(&1 in allowed)) and length(labels) >= 2 and
            Enum.all?(
              labels,
              &Regex.match?(~r/^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/, &1)
            ) and
            Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9-]+$/, List.last(labels))

        _ ->
          false
      end
    else
      false
    end
  end
end
