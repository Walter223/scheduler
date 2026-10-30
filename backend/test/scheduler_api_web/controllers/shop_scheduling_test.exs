defmodule SchedulerApiWeb.ShopSchedulingTest do
  use SchedulerApiWeb.ConnCase, async: true

  alias SchedulerApi.{Appointments, Catalog, Organizations, Repo}
  alias SchedulerApi.Appointments.{Appointment, Availability}
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures
  import SchedulerApi.ShopsFixtures
  import SchedulerApi.DataCase, only: [errors_on: 1]

  setup do
    price = service_price_fixture(%{duration_minutes: 90})
    other = shop_price_fixture(price)

    %{
      price: price,
      other: other,
      shop: Organizations.default_shop!(),
      attrs: booking_attrs(price)
    }
  end

  test "public catalog selects only default-shop offerings and prices", context do
    foreign = other_business_price_fixture()

    assert {:ok, service} =
             Catalog.create_service(%{name: "Only elsewhere", description: "Other shop only"})

    assert {:ok, _} =
             Catalog.create_service_price(context.other.shop, %{
               service_id: service.id,
               vehicle_size_id: context.price.vehicle_size_id,
               price_cents: 100,
               duration_minutes: 30
             })

    response =
      context.conn
      |> get("/api/services", %{
        shop_id: context.other.shop.id,
        business_id: foreign.shop.business_id
      })
      |> json_response(200)

    assert [%{"id" => service_id, "prices" => [price]}] = response
    assert service_id == context.price.service_id
    assert price["service_price_id"] == context.price.id
    assert price["price_cents"] == context.price.price_cents
    assert price["duration_minutes"] == 90
    assert Catalog.list_service_prices() == [context.price]
    assert_raise Ecto.NoResultsError, fn -> Catalog.get_service_price!(context.other.price.id) end

    assert Catalog.get_service_price!(context.other.shop, context.other.price.id) ==
             context.other.price

    assert_raise Ecto.NoResultsError, fn -> Catalog.get_service!(foreign.price.service_id) end

    assert_raise Ecto.NoResultsError, fn ->
      Catalog.get_vehicle_size!(foreign.price.vehicle_size_id)
    end
  end

  test "availability ignores overlapping appointments in another shop", context do
    assert {:ok, other} =
             Appointments.create_appointment(
               context.other.shop,
               booking_attrs(context.other.price)
             )

    assert other.shop_id == context.other.shop.id
    assert {:ok, available} = Availability.get(booking_date(), context.price.id)
    assert "09:00" in available.available_times

    assert {:ok, occupied} =
             Availability.get_for_shop(context.other.shop, booking_date(), context.other.price.id)

    refute "09:00" in occupied.available_times
    assert {:ok, _} = Appointments.create_appointment(context.attrs)
    assert {:ok, now_blocked} = Availability.get(booking_date(), context.price.id)
    refute "09:00" in now_blocked.available_times
    refute "10:30" in now_blocked.available_times
    assert "11:00" in now_blocked.available_times
  end

  test "public endpoints reject foreign-shop and foreign-business prices even with ownership params",
       context do
    foreign = other_business_price_fixture()

    for other <- [context.other, foreign] do
      params =
        Map.merge(booking_attrs(other.price), %{
          shop_id: other.shop.id,
          business_id: other.shop.business_id
        })

      response =
        context.conn |> recycle() |> post("/api/appointments", params) |> json_response(422)

      assert response["errors"]["service_price_id"] == ["does not exist"]

      response =
        context.conn
        |> recycle()
        |> get("/api/availability", %{
          date: Date.to_iso8601(booking_date()),
          service_price_id: other.price.id,
          shop_id: other.shop.id
        })
        |> json_response(404)

      assert response["error"]["code"] == "not_found"
    end

    assert {:error, changeset} =
             Appointments.create_appointment(context.other.shop, context.attrs)

    assert errors_on(changeset).service_price_id == ["does not exist"]
  end

  test "client ownership cannot override shop-validated price ownership", context do
    params =
      Map.merge(context.attrs, %{
        shop_id: context.other.shop.id,
        business_id: -1,
        price_cents: 1,
        duration_minutes: 1,
        status: "confirmed"
      })

    response = context.conn |> post("/api/appointments", params) |> json_response(201)
    stored = Repo.get!(Appointment, response["appointment"]["id"])
    assert stored.shop_id == context.shop.id
    assert stored.business_id == context.shop.business_id
    assert stored.price_cents == context.price.price_cents
    assert stored.duration_minutes == 90
    assert stored.status == :pending
    refute Map.has_key?(response["appointment"], "shop_id")
  end

  test "default retrieval and cursor pagination never return another shop's records", context do
    assert {:ok, first} = Appointments.create_appointment(context.attrs)

    assert {:ok, foreign} =
             Appointments.create_appointment(
               context.other.shop,
               booking_attrs(context.other.price)
             )

    assert {:ok, second} =
             Appointments.create_appointment(%{
               context.attrs
               | starts_at: DateTime.add(context.attrs.starts_at, 180 * 60)
             })

    assert Appointments.get_appointment(foreign.id) == nil
    assert_raise Ecto.NoResultsError, fn -> Appointments.get_appointment!(foreign.id) end
    assert Appointments.get_appointment(context.other.shop, foreign.id).id == foreign.id
    assert Enum.map(Appointments.list_appointments(), & &1.id) == [first.id, second.id]
    assert Enum.map(Appointments.list_appointments(context.other.shop), & &1.id) == [foreign.id]

    user = SchedulerApi.AccountsFixtures.active_user_fixture()
    SchedulerApi.AdminAccessFixtures.grant_fixture(user, context.shop, :shop_manager)
    {_, token} = SchedulerApi.AdminAccessFixtures.session_fixture(user)
    conn = put_req_cookie(context.conn, SchedulerApiWeb.BrowserSession.session_name(), token)

    assert conn
           |> get("/api/admin/appointments", %{shop_id: context.other.shop.id})
           |> json_response(403) == %{"error" => "forbidden"}

    page1 =
      conn
      |> get("/api/admin/appointments", %{limit: "1"})
      |> json_response(200)

    assert Enum.map(page1["appointments"], & &1["id"]) == [first.id]
    assert page1["meta"]["has_more"]

    page2 =
      conn
      |> recycle()
      |> get("/api/admin/appointments", %{limit: "1", cursor: page1["meta"]["next_cursor"]})
      |> json_response(200)

    assert Enum.map(page2["appointments"], & &1["id"]) == [second.id]
    refute page2["meta"]["has_more"]

    assert {:ok, foreign_page} =
             Appointments.list_upcoming_appointments(context.other.shop, limit: 1)

    assert Enum.map(foreign_page.appointments, & &1.id) == [foreign.id]

    foreign_cursor =
      [1, DateTime.to_iso8601(foreign.starts_at), foreign.id]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, safe_page} = Appointments.list_upcoming_appointments(cursor: foreign_cursor)
    assert Enum.all?(safe_page.appointments, &(&1.shop_id == context.shop.id))
    assert Enum.map(safe_page.appointments, & &1.id) == [second.id]
  end

  for status <- [:pending, :confirmed] do
    test "database rejects same-shop overlap with #{status}, but permits another shop", context do
      insert_direct(context.price, context.attrs.starts_at, unquote(status)) |> Repo.insert!()

      assert {:error, changeset} =
               insert_direct(context.price, context.attrs.starts_at, :pending)
               |> Repo.insert(mode: :savepoint)

      assert errors_on(changeset).starts_at == ["is no longer available"]

      assert {:error, _} =
               insert_direct(
                 context.price,
                 DateTime.add(context.attrs.starts_at, 90 * 60),
                 :confirmed
               )
               |> Repo.insert(mode: :savepoint)

      assert {:ok, _} =
               insert_direct(context.other.price, context.attrs.starts_at, :pending)
               |> Repo.insert()

      assert {:ok, _} =
               insert_direct(
                 context.price,
                 DateTime.add(context.attrs.starts_at, 120 * 60),
                 :pending
               )
               |> Repo.insert()

      for ignored <- [:cancelled, :completed] do
        assert {:ok, _} =
                 insert_direct(context.price, context.attrs.starts_at, ignored) |> Repo.insert()
      end
    end
  end

  test "cancelled/completed appointments do not block either shop", context do
    for status <- [:cancelled, :completed] do
      insert_direct(context.price, context.attrs.starts_at, status) |> Repo.insert!()
      insert_direct(context.other.price, context.attrs.starts_at, status) |> Repo.insert!()
    end

    assert {:ok, result} = Availability.get(booking_date(), context.price.id)
    assert "09:00" in result.available_times

    assert {:ok, result} =
             Availability.get_for_shop(context.other.shop, booking_date(), context.other.price.id)

    assert "09:00" in result.available_times
  end

  test "shop lock keys support bigint shop identities without truncation", context do
    shop =
      %SchedulerApi.Organizations.Shop{id: 3_000_000_001, business_id: context.shop.business_id}
      |> SchedulerApi.Organizations.Shop.changeset(%{
        name: "Big ID",
        slug: "big-id",
        timezone: "America/Denver"
      })
      |> Repo.insert!()

    assert {:ok, price} =
             Catalog.create_service_price(shop, %{
               service_id: context.price.service_id,
               vehicle_size_id: context.price.vehicle_size_id,
               price_cents: 100,
               duration_minutes: 60
             })

    assert {:ok, appointment} = Appointments.create_appointment(shop, booking_attrs(price))
    assert appointment.shop_id == 3_000_000_001
  end

  defp insert_direct(price, starts_at, status) do
    %Appointment{
      business_id: price.business_id,
      shop_id: price.shop_id,
      price_cents: price.price_cents,
      duration_minutes: price.duration_minutes,
      status: status
    }
    |> Appointment.changeset(%{booking_attrs(price) | starts_at: starts_at})
  end
end
