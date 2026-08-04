defmodule SchedulerApi.CatalogTest do
  use SchedulerApi.DataCase

  alias SchedulerApi.Catalog

  describe "services" do
    alias SchedulerApi.Catalog.Service

    import SchedulerApi.CatalogFixtures

    @invalid_attrs %{" name": nil, " description": nil}

    test "list_services/0 returns all services" do
      service = service_fixture()
      assert Catalog.list_services() == [service]
    end

    test "get_service!/1 returns the service with given id" do
      service = service_fixture()
      assert Catalog.get_service!(service.id) == service
    end

    test "create_service/1 with valid data creates a service" do
      valid_attrs = %{" name": "some  name", " description": "some  description"}

      assert {:ok, %Service{} = service} = Catalog.create_service(valid_attrs)
      assert service.name == "some  name"
      assert service.description == "some  description"
    end

    test "create_service/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Catalog.create_service(@invalid_attrs)
    end

    test "update_service/2 with valid data updates the service" do
      service = service_fixture()
      update_attrs = %{" name": "some updated  name", " description": "some updated  description"}

      assert {:ok, %Service{} = service} = Catalog.update_service(service, update_attrs)
      assert service.name == "some updated  name"
      assert service.description == "some updated  description"
    end

    test "update_service/2 with invalid data returns error changeset" do
      service = service_fixture()
      assert {:error, %Ecto.Changeset{}} = Catalog.update_service(service, @invalid_attrs)
      assert service == Catalog.get_service!(service.id)
    end

    test "delete_service/1 deletes the service" do
      service = service_fixture()
      assert {:ok, %Service{}} = Catalog.delete_service(service)
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_service!(service.id) end
    end

    test "change_service/1 returns a service changeset" do
      service = service_fixture()
      assert %Ecto.Changeset{} = Catalog.change_service(service)
    end
  end

  describe "vehicle_sizes" do
    alias SchedulerApi.Catalog.VehicleSize

    import SchedulerApi.CatalogFixtures

    @invalid_attrs %{" name": nil, " sort_order": nil}

    test "list_vehicle_sizes/0 returns all vehicle_sizes" do
      vehicle_size = vehicle_size_fixture()
      assert Catalog.list_vehicle_sizes() == [vehicle_size]
    end

    test "get_vehicle_size!/1 returns the vehicle_size with given id" do
      vehicle_size = vehicle_size_fixture()
      assert Catalog.get_vehicle_size!(vehicle_size.id) == vehicle_size
    end

    test "create_vehicle_size/1 with valid data creates a vehicle_size" do
      valid_attrs = %{" name": "some  name", " sort_order": 42}

      assert {:ok, %VehicleSize{} = vehicle_size} = Catalog.create_vehicle_size(valid_attrs)
      assert vehicle_size.name == "some  name"
      assert vehicle_size.sort_order == 42
    end

    test "create_vehicle_size/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Catalog.create_vehicle_size(@invalid_attrs)
    end

    test "update_vehicle_size/2 with valid data updates the vehicle_size" do
      vehicle_size = vehicle_size_fixture()
      update_attrs = %{" name": "some updated  name", " sort_order": 43}

      assert {:ok, %VehicleSize{} = vehicle_size} =
               Catalog.update_vehicle_size(vehicle_size, update_attrs)

      assert vehicle_size.name == "some updated  name"
      assert vehicle_size.sort_order == 43
    end

    test "update_vehicle_size/2 with invalid data returns error changeset" do
      vehicle_size = vehicle_size_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Catalog.update_vehicle_size(vehicle_size, @invalid_attrs)

      assert vehicle_size == Catalog.get_vehicle_size!(vehicle_size.id)
    end

    test "delete_vehicle_size/1 deletes the vehicle_size" do
      vehicle_size = vehicle_size_fixture()
      assert {:ok, %VehicleSize{}} = Catalog.delete_vehicle_size(vehicle_size)
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_vehicle_size!(vehicle_size.id) end
    end

    test "change_vehicle_size/1 returns a vehicle_size changeset" do
      vehicle_size = vehicle_size_fixture()
      assert %Ecto.Changeset{} = Catalog.change_vehicle_size(vehicle_size)
    end
  end

  describe "service_prices" do
    alias SchedulerApi.Catalog.ServicePrice

    import SchedulerApi.CatalogFixtures

    @invalid_attrs %{" price_cents": nil}

    test "list_service_prices/0 returns all service_prices" do
      service_price = service_price_fixture()
      assert Catalog.list_service_prices() == [service_price]
    end

    test "get_service_price!/1 returns the service_price with given id" do
      service_price = service_price_fixture()
      assert Catalog.get_service_price!(service_price.id) == service_price
    end

    test "create_service_price/1 with valid data creates a service_price" do
      valid_attrs = %{" price_cents": 42}

      assert {:ok, %ServicePrice{} = service_price} = Catalog.create_service_price(valid_attrs)
      assert service_price.price_cents == 42
    end

    test "create_service_price/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Catalog.create_service_price(@invalid_attrs)
    end

    test "update_service_price/2 with valid data updates the service_price" do
      service_price = service_price_fixture()
      update_attrs = %{" price_cents": 43}

      assert {:ok, %ServicePrice{} = service_price} =
               Catalog.update_service_price(service_price, update_attrs)

      assert service_price.price_cents == 43
    end

    test "update_service_price/2 with invalid data returns error changeset" do
      service_price = service_price_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Catalog.update_service_price(service_price, @invalid_attrs)

      assert service_price == Catalog.get_service_price!(service_price.id)
    end

    test "delete_service_price/1 deletes the service_price" do
      service_price = service_price_fixture()
      assert {:ok, %ServicePrice{}} = Catalog.delete_service_price(service_price)
      assert_raise Ecto.NoResultsError, fn -> Catalog.get_service_price!(service_price.id) end
    end

    test "change_service_price/1 returns a service_price changeset" do
      service_price = service_price_fixture()
      assert %Ecto.Changeset{} = Catalog.change_service_price(service_price)
    end
  end
end
