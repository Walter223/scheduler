defmodule SchedulerApi.BusinessOnboarding.BaseValidation do
  @moduledoc false
  # 7A-1 uses the common typed proposal fields only; mobile/location extensions
  # remain unwired until its checkpoint is verified.
  alias SchedulerApi.BusinessOnboarding.Validation
  def empty, do: Validation.empty()

  def valid?(p, business_id) do
    Validation.valid?(p, business_id) and p["defaults"] == %{} and
      Enum.all?(p["locations"], fn l ->
        Enum.all?(Map.keys(l), &(&1 in ~w(key existing_shop_id name timezone operating_model))) and
          l["operating_model"] == "in_shop"
      end)
  end
end
