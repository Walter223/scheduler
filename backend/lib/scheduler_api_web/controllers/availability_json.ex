defmodule SchedulerApiWeb.AvailabilityJSON do
  def index(%{availability: availability}), do: availability
  def error(%{error: error}), do: %{error: error}
end
