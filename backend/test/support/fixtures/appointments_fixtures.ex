defmodule SchedulerApi.AppointmentsFixtures do
  @moduledoc "Shared valid booking input; dates are relative to Denver today."

  alias SchedulerApi.Appointments.Availability

  def booking_date do
    tomorrow =
      DateTime.utc_now()
      |> Availability.local_datetime()
      |> NaiveDateTime.to_date()
      |> Date.add(1)

    if Date.day_of_week(tomorrow) == 7, do: Date.add(tomorrow, 1), else: tomorrow
  end

  def booking_attrs(price, date \\ booking_date()) do
    {opens, _} = Availability.business_hours(date)

    %{
      service_price_id: price.id,
      starts_at: opens,
      customer_first_name: "Alex",
      customer_last_name: "Driver",
      customer_email: "alex@example.com",
      customer_phone: "+1 303 555 0100",
      vehicle_make: "Toyota",
      vehicle_model: "Camry"
    }
  end
end
