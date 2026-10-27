defmodule SchedulerApiWeb.AppointmentControllerTest do
  use SchedulerApiWeb.ConnCase, async: true

  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  alias SchedulerApi.Appointments

  setup do
    %{attrs: booking_attrs(service_price_fixture())}
  end

  test "POST persists separate trimmed names and returns no combined name", %{
    conn: conn,
    attrs: attrs
  } do
    params =
      Map.merge(attrs, %{
        customer_first_name: "  Alex Jane  ",
        customer_last_name: "  van Driver  ",
        customer_name: "Ignored Legacy Name"
      })

    response = conn |> post("/api/appointments", params) |> json_response(201)
    appointment = response["appointment"]
    assert appointment["customer_first_name"] == "Alex Jane"
    assert appointment["customer_last_name"] == "van Driver"
    refute Map.has_key?(appointment, "customer_name")
    stored = Appointments.get_appointment!(appointment["id"])
    assert stored.customer_first_name == appointment["customer_first_name"]
    assert stored.customer_last_name == appointment["customer_last_name"]
    assert stored.price_cents == appointment["price_cents"]
    assert appointment["status"] == "pending"
  end

  test "POST returns field-specific errors for missing, blank, and oversized names", %{
    conn: conn,
    attrs: attrs
  } do
    for field <- [:customer_first_name, :customer_last_name],
        value <- [nil, "", " \t\n ", String.duplicate("A", 101)] do
      params = if value == nil, do: Map.delete(attrs, field), else: Map.put(attrs, field, value)
      response = conn |> recycle() |> post("/api/appointments", params) |> json_response(422)

      message =
        if is_binary(value) and String.length(value) == 101,
          do: "should be at most 100 character(s)",
          else: "can't be blank"

      assert message in response["errors"][Atom.to_string(field)]
    end

    assert Appointments.list_appointments() == []
  end

  test "legacy customer_name alone cannot satisfy either required name", %{
    conn: conn,
    attrs: attrs
  } do
    params =
      attrs
      |> Map.drop([:customer_first_name, :customer_last_name])
      |> Map.put(:customer_name, "Alex Driver")

    response = conn |> post("/api/appointments", params) |> json_response(422)
    assert response["errors"]["customer_first_name"] == ["can't be blank"]
    assert response["errors"]["customer_last_name"] == ["can't be blank"]
    refute Map.has_key?(response["errors"], "customer_name")
  end
end
