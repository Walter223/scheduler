defmodule SchedulerApiWeb.AvailabilityJSON do
  def index(%{availability: availability}) do
    %{
      date: availability.date,
      service_price_id: availability.service_price_id,
      duration_minutes: availability.duration_minutes,
      available_times: availability.available_times
    }
  end

  def error(%{
        error: %{
          field: field,
          code: code,
          message: message
        }
      }) do
    %{
      error: %{
        field: field,
        code: code,
        message: message
      }
    }
  end
end
