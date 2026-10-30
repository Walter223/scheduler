defmodule SchedulerApiWeb.AdminAppointmentsTest do
  use SchedulerApiWeb.ConnCase, async: true

  alias SchedulerApi.{Catalog, Repo}
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Catalog.{Service, VehicleSize}
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures

  @path "/api/admin/appointments"

  setup %{conn: conn} do
    user = SchedulerApi.AccountsFixtures.active_user_fixture()

    SchedulerApi.AdminAccessFixtures.grant_fixture(
      user,
      SchedulerApi.Organizations.default_shop!(),
      :business_owner
    )

    {_, token} = SchedulerApi.AdminAccessFixtures.session_fixture(user)
    conn = put_req_cookie(conn, SchedulerApiWeb.BrowserSession.session_name(), token)
    price = service_price_fixture(%{price_cents: 8999, duration_minutes: 90})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      conn: conn,
      price: price,
      attrs: booking_attrs(price),
      future: DateTime.add(now, 86_400),
      now: now
    }
  end

  test "successful list has the exact fields, current catalog names, UTC time and stored snapshots",
       context do
    appointment = insert_booking(context, context.future)

    assert {:ok, _} =
             Catalog.update_service_price(context.price, %{
               price_cents: 19999,
               duration_minutes: 150
             })

    assert {:ok, _} =
             Catalog.update_service(Repo.get!(Service, context.price.service_id), %{
               name: "Current package"
             })

    assert {:ok, _} =
             Catalog.update_vehicle_size(Repo.get!(VehicleSize, context.price.vehicle_size_id), %{
               name: "Current size"
             })

    response = context.conn |> get(@path) |> json_response(200)
    assert Map.keys(response) |> Enum.sort() == ["appointments", "meta"]

    assert response["appointments"] == [
             %{
               "id" => appointment.id,
               "service_price_id" => context.price.id,
               "customer_first_name" => "Alex",
               "customer_last_name" => "Driver",
               "customer_email" => "alex@example.com",
               "customer_phone" => "+1 303 555 0100",
               "vehicle_make" => "Toyota",
               "vehicle_model" => "Camry",
               "service_name" => "Current package",
               "vehicle_size" => "Current size",
               "starts_at" => DateTime.to_iso8601(context.future),
               "duration_minutes" => 90,
               "price_cents" => 8999,
               "notes" => nil,
               "status" => "pending"
             }
           ]

    assert response["meta"] == %{
             "timezone" => "America/Denver",
             "has_more" => false,
             "next_cursor" => nil
           }

    assert String.ends_with?(hd(response["appointments"])["starts_at"], "Z")
  end

  test "empty list includes complete final-page metadata", %{conn: conn} do
    assert conn |> get(@path) |> json_response(200) == %{
             "appointments" => [],
             "meta" => %{
               "timezone" => "America/Denver",
               "has_more" => false,
               "next_cursor" => nil
             }
           }
  end

  test "lists upcoming pending and confirmed chronologically, excluding past/cancelled/completed",
       context do
    later =
      insert_booking(context, DateTime.add(context.future, 7200), :confirmed, %{
        notes: "Call on arrival"
      })

    earlier = insert_booking(context, context.future)
    insert_booking(context, DateTime.add(context.now, -7200))
    insert_booking(context, DateTime.add(context.future, 14_400), :cancelled)
    insert_booking(context, DateTime.add(context.future, 21_600), :completed)
    response = context.conn |> get(@path) |> json_response(200)
    assert ids(response) == [earlier.id, later.id]
    assert Enum.map(response["appointments"], & &1["status"]) == ["pending", "confirmed"]
    assert List.last(response["appointments"])["notes"] == "Call on arrival"
  end

  test "default limit is 50 with a continuation cursor", context do
    appointments = insert_many(context, 51)
    response = context.conn |> get(@path) |> json_response(200)
    assert ids(response) == Enum.map(Enum.take(appointments, 50), & &1.id)
    assert response["meta"]["has_more"]
    assert is_binary(response["meta"]["next_cursor"])
  end

  test "valid limits and cursors return successive pages and final metadata", context do
    [first, second, third] = insert_many(context, 3)
    page1 = context.conn |> get(@path, %{limit: "2"}) |> json_response(200)
    assert ids(page1) == [first.id, second.id]
    assert page1["meta"]["has_more"]
    cursor = page1["meta"]["next_cursor"]
    assert is_binary(cursor)

    page2 =
      context.conn |> recycle() |> get(@path, %{limit: "2", cursor: cursor}) |> json_response(200)

    assert ids(page2) == [third.id]

    assert page2["meta"] == %{
             "timezone" => "America/Denver",
             "has_more" => false,
             "next_cursor" => nil
           }
  end

  test "a full final page has no continuation", context do
    insert_many(context, 2)
    response = context.conn |> get(@path, %{limit: "2"}) |> json_response(200)
    assert length(response["appointments"]) == 2
    refute response["meta"]["has_more"]
    assert response["meta"]["next_cursor"] == nil
  end

  test "maximum limit of 100 is accepted and 101 is rejected", context do
    insert_many(context, 101)
    response = context.conn |> get(@path, %{limit: "100"}) |> json_response(200)
    assert length(response["appointments"]) == 100
    assert response["meta"]["has_more"]
    error = context.conn |> recycle() |> get(@path, %{limit: "101"}) |> json_response(422)

    assert error == %{
             "error" => %{"field" => "limit", "message" => "must be an integer from 1 to 100"}
           }
  end

  test "malformed, blank, nonpositive and nested limits return field-specific 422 errors", %{
    conn: conn
  } do
    for limit <- [
          "",
          "bad",
          "0",
          "-1",
          "1.5",
          "10abc",
          " 2",
          "100000000000000000000",
          ["1"],
          %{"value" => "2"}
        ] do
      error = conn |> recycle() |> get(@path, %{limit: limit}) |> json_response(422)

      assert error == %{
               "error" => %{"field" => "limit", "message" => "must be an integer from 1 to 100"}
             }
    end
  end

  test "malformed, blank and nested cursors return field-specific 422 errors", %{conn: conn} do
    for cursor <- [
          "",
          "!invalid",
          Base.url_encode64("{}", padding: false),
          String.duplicate("a", 513),
          ["bad"],
          %{"value" => "bad"}
        ] do
      error = conn |> recycle() |> get(@path, %{cursor: cursor}) |> json_response(422)

      assert error == %{
               "error" => %{
                 "field" => "cursor",
                 "message" => "must be a valid upcoming-appointments cursor"
               }
             }
    end
  end

  test "client parameters cannot override the server clock or status filter", context do
    insert_booking(context, DateTime.add(context.now, -7200))
    insert_booking(context, DateTime.add(context.future, 7200), :cancelled)
    upcoming = insert_booking(context, context.future)

    response =
      context.conn
      |> get(@path, %{now: "2020-01-01T00:00:00Z", status: "cancelled"})
      |> json_response(200)

    assert ids(response) == [upcoming.id]
  end

  test "POST retains its existing singular response without list-only fields", context do
    response = context.conn |> post("/api/appointments", context.attrs) |> json_response(201)
    assert Map.keys(response) == ["appointment"]
    refute Map.has_key?(response["appointment"], "service_name")
    refute Map.has_key?(response["appointment"], "vehicle_size")
    refute Map.has_key?(response, "meta")
    assert response["appointment"]["customer_first_name"] == "Alex"
    assert response["appointment"]["price_cents"] == 8999
  end

  defp insert_booking(context, starts_at, status \\ :pending, attrs \\ %{}) do
    # Query fixtures retain all database constraints without creation-window rules.
    %Appointment{
      business_id: context.price.business_id,
      shop_id: context.price.shop_id,
      price_cents: context.price.price_cents,
      duration_minutes: context.price.duration_minutes,
      status: status
    }
    |> Appointment.changeset(context.attrs |> Map.put(:starts_at, starts_at) |> Map.merge(attrs))
    |> Repo.insert!()
  end

  defp insert_many(context, count) do
    for index <- 0..(count - 1),
        do: insert_booking(context, DateTime.add(context.future, index * 7200))
  end

  defp ids(response), do: Enum.map(response["appointments"], & &1["id"])
end
