defmodule SchedulerApiWeb.AvailabilityControllerTest do
  use SchedulerApiWeb.ConnCase, async: true

  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  alias SchedulerApi.Appointments.Availability

  setup do
    %{price: service_price_fixture(%{duration_minutes: 90})}
  end

  test "GET returns structured local start times", %{conn: conn, price: price} do
    date = Date.to_iso8601(booking_date())
    conn = get(conn, "/api/availability", %{date: date, service_price_id: price.id})
    result = json_response(conn, 200)
    assert result["date"] == date
    assert result["service_price_id"] == price.id
    assert result["duration_minutes"] == 90
    assert hd(result["available_times"]) == "09:00"
    assert List.last(result["available_times"]) == "16:00"
  end

  test "invalid requests return structured 422 errors", %{conn: conn, price: price} do
    today = DateTime.utc_now() |> Availability.local_datetime() |> NaiveDateTime.to_date()

    sunday =
      Enum.find(Date.range(Date.add(today, 1), Date.add(today, 7)), &(Date.day_of_week(&1) == 7))

    for {params, code} <- [
          {%{}, "invalid_date"},
          {%{date: "not-a-date", service_price_id: price.id}, "invalid_date"},
          {%{date: "2026-02-30", service_price_id: price.id}, "invalid_date"},
          {%{date: Date.to_iso8601(Date.add(today, -1)), service_price_id: price.id},
           "past_date"},
          {%{date: Date.to_iso8601(Date.add(today, 91)), service_price_id: price.id},
           "outside_booking_window"},
          {%{date: Date.to_iso8601(sunday), service_price_id: price.id}, "closed_sunday"},
          {%{date: Date.to_iso8601(booking_date()), service_price_id: "bad"},
           "invalid_service_price_id"},
          {%{date: Date.to_iso8601(booking_date())}, "invalid_service_price_id"},
          {%{date: Date.to_iso8601(booking_date()), service_price_id: "9999999999999999999999"},
           "invalid_service_price_id"}
        ] do
      response = conn |> get("/api/availability", params) |> json_response(422)
      assert response["error"]["code"] == code
      assert is_binary(response["error"]["message"])
      assert response["error"]["field"] in ["date", "service_price_id"]
    end
  end

  test "nonexistent service price returns 404", %{conn: conn} do
    conn =
      get(conn, "/api/availability", %{
        date: Date.to_iso8601(booking_date()),
        service_price_id: 9_000_000_000
      })

    assert %{"error" => %{"code" => "not_found", "field" => "service_price_id"}} =
             json_response(conn, 404)
  end
end
