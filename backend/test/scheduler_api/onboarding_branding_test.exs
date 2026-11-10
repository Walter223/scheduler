defmodule SchedulerApi.OnboardingBrandingTest do
  use ExUnit.Case, async: true
  alias SchedulerApi.BusinessOnboarding.BrandingValidation, as: V

  test "strict proposals, presets and incomplete drafts" do
    b = %{
      "display_name" => "Fictional",
      "contact_email" => "public@example.invalid",
      "contact_phone" => "+1 (555) 010-1234",
      "primary_color" => "#123456",
      "secondary_color" => "#abcdef",
      "accent_color" => "#AABBCC",
      "preset" => "modern"
    }

    for preset <- ~w(modern premium minimal),
        do: assert(V.complete?(Map.put(b, "preset", preset)))

    assert V.valid?(%{})
    refute V.complete?(%{})

    for {key, value} <- [
          {"contact_email", "bad"},
          {"contact_email", ".bad@example.invalid"},
          {"contact_email", "bad.@example.invalid"},
          {"contact_phone", "123"},
          {"primary_color", "red"},
          {"accent_color", "#fff"},
          {"preset", "script"},
          {"display_name", String.duplicate("a", 256)},
          {"logo_url", "https://invalid.example"},
          {"password", "forbidden"}
        ] do
      refute V.valid?(Map.put(b, key, value))
    end
  end
end
