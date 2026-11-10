defmodule SchedulerApi.BusinessOnboarding.BrandingValidation do
  @moduledoc false
  @fields ~w(display_name tagline description contact_email contact_phone primary_color secondary_color accent_color preset)
  def valid?(b) when is_map(b) do
    Enum.all?(Map.keys(b), &(&1 in @fields)) and
      Enum.all?(b, fn
        {"preset", v} ->
          v in ~w(modern premium minimal)

        {k, v} when k in ~w(primary_color secondary_color accent_color) ->
          is_binary(v) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, v)

        {"contact_email", v} ->
          text?(v, 254) and
            Regex.match?(
              ~r/^(?!\.)(?!.*\.@)[A-Za-z0-9.!#$%&'*+\/= ?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$/,
              v
            ) and not String.contains?(v, " ") and not String.contains?(v, "..")

        {"contact_phone", v} ->
          text?(v, 40) and Regex.match?(~r/^\+?[0-9 ()-]+$/, v) and
            String.length(Regex.replace(~r/\D/, v, "")) in 7..15

        {"description", v} ->
          text?(v, 2000)

        {"tagline", v} ->
          text?(v, 200)

        {"display_name", v} ->
          text?(v, 255)
      end)
  end

  def valid?(_), do: false

  def complete?(b),
    do:
      valid?(b) and
        Enum.all?(
          ~w(display_name contact_email contact_phone primary_color secondary_color accent_color preset),
          &Map.has_key?(b, &1)
        )

  defp text?(v, max),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..max and String.trim(v) == v and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, v)
end
