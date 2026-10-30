defmodule SchedulerApi.OrganizationsTest do
  use SchedulerApi.DataCase, async: true

  alias SchedulerApi.{Organizations, Catalog}
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.Catalog.{Service, ServicePrice, VehicleSize}
  alias SchedulerApi.Appointments.Appointment
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.AppointmentsFixtures

  test "the default tenant is resolved by stable identity, not the first row" do
    assert Repo.aggregate(Business, :count) == 1
    assert Repo.aggregate(Shop, :count) == 1
    business = Organizations.default_business!()
    shop = Organizations.default_shop!()
    assert business.name == "Magnum Detailing"
    assert business.status == :active
    assert shop.business_id == business.id
    assert shop.timezone == "America/Denver"
    assert shop.status == :active
  end

  test "new catalog and booking ownership is server-assigned without new payload fields" do
    business = Organizations.default_business!()
    shop = Organizations.default_shop!()
    price = service_price_fixture()
    assert price.business_id == business.id
    assert price.shop_id == shop.id
    assert Repo.get!(Service, price.service_id).business_id == business.id
    assert Repo.get!(VehicleSize, price.vehicle_size_id).business_id == business.id
    attrs = booking_attrs(price) |> Map.merge(%{business_id: -1, shop_id: -1})
    assert {:ok, appointment} = SchedulerApi.Appointments.create_appointment(attrs)
    assert appointment.business_id == business.id
    assert appointment.shop_id == shop.id
    assert appointment.price_cents == price.price_cents
    assert appointment.duration_minutes == price.duration_minutes
    assert appointment.status == :pending
  end

  test "ownership is not mass-assignable through catalog changesets" do
    price = service_price_fixture()
    assert {:ok, updated} = Catalog.update_service_price(price, %{business_id: -1, shop_id: -1})
    assert updated.business_id == price.business_id
    assert updated.shop_id == price.shop_id

    assert {:ok, service} =
             Catalog.create_service(%{name: "Owned", description: "Detail", business_id: -1})

    assert service.business_id == Organizations.default_business!().id
  end

  test "composite foreign keys reject cross-business and cross-shop combinations" do
    price = service_price_fixture()
    assert {:ok, appointment} = SchedulerApi.Appointments.create_appointment(booking_attrs(price))
    size_for_price = vehicle_size_fixture(%{name: "Unreferenced", sort_order: 43})

    assert {:ok, unreferenced_price} =
             Catalog.create_service_price(%{
               service_id: price.service_id,
               vehicle_size_id: size_for_price.id,
               price_cents: 5000,
               duration_minutes: 60
             })

    other_business =
      %Business{}
      |> Business.changeset(%{name: "Other Business", slug: "other"})
      |> Repo.insert!()

    other_shop =
      %Shop{business_id: other_business.id}
      |> Shop.changeset(%{name: "Other", slug: "default", timezone: "America/Denver"})
      |> Repo.insert!()

    same_business_shop =
      %Shop{business_id: price.business_id}
      |> Shop.changeset(%{name: "Second", slug: "second", timezone: "America/Denver"})
      |> Repo.insert!()

    # Names/order can repeat in another business without sharing ownership.
    service =
      %Service{business_id: other_business.id}
      |> Service.changeset(%{name: "some  name", description: "Other"})
      |> Repo.insert!()

    size =
      %VehicleSize{business_id: other_business.id}
      |> VehicleSize.changeset(%{name: "some  name", sort_order: 42})
      |> Repo.insert!()

    other_price =
      %ServicePrice{business_id: other_business.id, shop_id: other_shop.id}
      |> ServicePrice.changeset(%{
        service_id: service.id,
        vehicle_size_id: size.id,
        price_cents: 5000,
        duration_minutes: 60
      })
      |> Repo.insert!()

    for {table, id, field, value, constraint} <- [
          {"service_prices", price.id, "service_id", service.id,
           "service_prices_service_business_fkey"},
          {"service_prices", price.id, "vehicle_size_id", size.id,
           "service_prices_vehicle_size_business_fkey"},
          {"service_prices", price.id, "shop_id", other_shop.id,
           "service_prices_shop_business_fkey"},
          {"appointments", appointment.id, "shop_id", same_business_shop.id,
           "appointments_price_ownership_fkey"},
          {"appointments", appointment.id, "service_price_id", other_price.id,
           "appointments_price_ownership_fkey"},
          {"appointments", appointment.id, "shop_id", other_shop.id,
           "appointments_shop_business_fkey"}
        ] do
      assert {:error, %Postgrex.Error{postgres: error}} =
               Repo.query(
                 "UPDATE #{table} SET #{field} = $1 WHERE id = $2",
                 [value, if(table == "service_prices", do: unreferenced_price.id, else: id)],
                 mode: :savepoint
               )

      assert error.code == :foreign_key_violation
      assert error.constraint == constraint
    end
  end

  test "ownership columns reject null and tenant deletion cannot orphan data" do
    # DELETE upgrades the parent row lock and conflicts with foreign-key locks
    # held by parallel fixtures. Never delete the shared default tenant here.
    %{price: price, shop: shop} = SchedulerApi.ShopsFixtures.other_business_price_fixture()
    refute price.business_id == Organizations.default_business!().id
    refute shop.id == Organizations.default_shop!().id

    assert {:ok, appointment} =
             SchedulerApi.Appointments.create_appointment(shop, booking_attrs(price))

    for {table, id, field} <- [
          {"services", price.service_id, "business_id"},
          {"vehicle_sizes", price.vehicle_size_id, "business_id"},
          {"service_prices", price.id, "business_id"},
          {"service_prices", price.id, "shop_id"},
          {"appointments", appointment.id, "business_id"},
          {"appointments", appointment.id, "shop_id"}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
               Repo.query(
                 "UPDATE #{table} SET #{field} = NULL WHERE id = $1",
                 [id],
                 mode: :savepoint
               )
    end

    for {table, id} <- [{"businesses", price.business_id}, {"shops", price.shop_id}] do
      assert {:error, %Postgrex.Error{postgres: error}} =
               Repo.query(
                 "DELETE FROM #{table} WHERE id = $1",
                 [id],
                 mode: :savepoint
               )

      assert error.code in [:foreign_key_violation, :restrict_violation]
    end

    assert Repo.get!(Appointment, appointment.id).notes == appointment.notes
  end

  test "business/shop slugs and lifecycle statuses are constrained" do
    business = Organizations.default_business!()

    for {table, id, field, value} <- [
          {"businesses", business.id, "status", "invalid"},
          {"businesses", business.id, "slug", "Bad Slug"},
          {"shops", Organizations.default_shop!().id, "status", "invalid"},
          {"shops", Organizations.default_shop!().id, "timezone", " "}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "UPDATE #{table} SET #{field} = $1 WHERE id = $2",
                 [value, id],
                 mode: :savepoint
               )
    end

    assert {:error, changeset} =
             %Business{}
             |> Business.changeset(%{name: "Duplicate", slug: business.slug})
             |> Repo.insert()

    assert errors_on(changeset).slug
  end

  test "seeds are repeatable and do not overwrite existing data or timestamps" do
    seed = Path.expand("../../priv/repo/seeds.exs", __DIR__)
    Code.eval_file(seed)
    price = Repo.one!(from p in ServicePrice, limit: 1)

    assert {:ok, _} =
             Catalog.update_service_price(price, %{price_cents: 12345, duration_minutes: 200})

    before = seeded_rows()
    Code.eval_file(seed)
    Code.eval_file(seed)
    assert seeded_rows() == before
    assert Repo.aggregate(Business, :count) == 1
    assert Repo.aggregate(Shop, :count) == 1
    assert Repo.aggregate(Service, :count) == 3
    assert Repo.aggregate(VehicleSize, :count) == 3
    assert Repo.aggregate(ServicePrice, :count) == 9
  end

  defp seeded_rows do
    for schema <- [Service, VehicleSize, ServicePrice],
        do: Repo.all(from r in schema, order_by: r.id)
  end
end
