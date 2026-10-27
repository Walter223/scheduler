defmodule SchedulerApi.Catalog do
  @moduledoc """
  The Catalog context.
  """

  import Ecto.Query, warn: false
  alias SchedulerApi.{Repo, Organizations}

  alias SchedulerApi.Catalog.Service
  alias SchedulerApi.Organizations.Shop

  @doc """
  Returns the list of services.

  ## Examples

      iex> list_services()
      [%Service{}, ...]

  """
  def list_services, do: list_services(Organizations.default_shop!())

  def list_services(%Shop{} = shop) do
    Repo.all(from s in Service, where: s.business_id == ^shop.business_id)
  end

  @doc """
  Returns services with their service prices and vehicle sizes loaded.
  """
  def list_services_with_prices, do: list_services_with_prices(Organizations.default_shop!())

  def list_services_with_prices(%Shop{} = shop) do
    prices = service_price_query(shop) |> order_by([p], asc: p.id) |> preload(:vehicle_size)

    Repo.all(
      from s in Service,
        join: p in subquery(service_price_query(shop)),
        on: p.service_id == s.id,
        where: s.business_id == ^shop.business_id,
        distinct: true,
        order_by: s.id,
        preload: [service_prices: ^prices]
    )
  end

  @doc """
  Gets a single service.

  Raises `Ecto.NoResultsError` if the Service does not exist.

  ## Examples

      iex> get_service!(123)
      %Service{}

      iex> get_service!(456)
      ** (Ecto.NoResultsError)

  """
  def get_service!(id), do: get_service!(Organizations.default_shop!(), id)

  def get_service!(%Shop{} = shop, id),
    do: Repo.one!(from s in Service, where: s.id == ^id and s.business_id == ^shop.business_id)

  @doc """
  Creates a service.

  ## Examples

      iex> create_service(%{field: value})
      {:ok, %Service{}}

      iex> create_service(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_service(attrs) do
    %Service{business_id: Organizations.default_business!().id}
    |> Service.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a service.

  ## Examples

      iex> update_service(service, %{field: new_value})
      {:ok, %Service{}}

      iex> update_service(service, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_service(%Service{} = service, attrs) do
    service
    |> Service.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a service.

  ## Examples

      iex> delete_service(service)
      {:ok, %Service{}}

      iex> delete_service(service)
      {:error, %Ecto.Changeset{}}

  """
  def delete_service(%Service{} = service) do
    Repo.delete(service)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking service changes.

  ## Examples

      iex> change_service(service)
      %Ecto.Changeset{data: %Service{}}

  """
  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end

  alias SchedulerApi.Catalog.VehicleSize

  @doc """
  Returns the list of vehicle_sizes.

  ## Examples

      iex> list_vehicle_sizes()
      [%VehicleSize{}, ...]

  """
  def list_vehicle_sizes do
    shop = Organizations.default_shop!()
    Repo.all(from v in VehicleSize, where: v.business_id == ^shop.business_id)
  end

  @doc """
  Gets a single vehicle_size.

  Raises `Ecto.NoResultsError` if the Vehicle size does not exist.

  ## Examples

      iex> get_vehicle_size!(123)
      %VehicleSize{}

      iex> get_vehicle_size!(456)
      ** (Ecto.NoResultsError)

  """
  def get_vehicle_size!(id) do
    shop = Organizations.default_shop!()
    Repo.one!(from v in VehicleSize, where: v.id == ^id and v.business_id == ^shop.business_id)
  end

  @doc """
  Creates a vehicle_size.

  ## Examples

      iex> create_vehicle_size(%{field: value})
      {:ok, %VehicleSize{}}

      iex> create_vehicle_size(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vehicle_size(attrs) do
    %VehicleSize{business_id: Organizations.default_business!().id}
    |> VehicleSize.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a vehicle_size.

  ## Examples

      iex> update_vehicle_size(vehicle_size, %{field: new_value})
      {:ok, %VehicleSize{}}

      iex> update_vehicle_size(vehicle_size, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_vehicle_size(%VehicleSize{} = vehicle_size, attrs) do
    vehicle_size
    |> VehicleSize.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a vehicle_size.

  ## Examples

      iex> delete_vehicle_size(vehicle_size)
      {:ok, %VehicleSize{}}

      iex> delete_vehicle_size(vehicle_size)
      {:error, %Ecto.Changeset{}}

  """
  def delete_vehicle_size(%VehicleSize{} = vehicle_size) do
    Repo.delete(vehicle_size)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking vehicle_size changes.

  ## Examples

      iex> change_vehicle_size(vehicle_size)
      %Ecto.Changeset{data: %VehicleSize{}}

  """
  def change_vehicle_size(%VehicleSize{} = vehicle_size, attrs \\ %{}) do
    VehicleSize.changeset(vehicle_size, attrs)
  end

  alias SchedulerApi.Catalog.ServicePrice

  @doc """
  Returns the list of service_prices.

  ## Examples

      iex> list_service_prices()
      [%ServicePrice{}, ...]

  """
  def list_service_prices,
    do: Organizations.default_shop!() |> service_price_query() |> Repo.all()

  @doc """
  Gets a single service_price.

  Raises `Ecto.NoResultsError` if the Service price does not exist.

  ## Examples

      iex> get_service_price!(123)
      %ServicePrice{}

      iex> get_service_price!(456)
      ** (Ecto.NoResultsError)

  """
  def get_service_price!(id), do: get_service_price!(Organizations.default_shop!(), id)

  def get_service_price!(%Shop{} = shop, id),
    do: Repo.one!(from p in service_price_query(shop), where: p.id == ^id)

  @doc "Trusted server-side shop boundary for price resolution; never populated from public query params."
  def service_price_query(%Shop{} = shop) do
    from p in ServicePrice,
      join: s in assoc(p, :service),
      join: v in assoc(p, :vehicle_size),
      where: p.shop_id == ^shop.id and p.business_id == ^shop.business_id,
      where: s.business_id == ^shop.business_id and v.business_id == ^shop.business_id,
      select: p
  end

  @doc """
  Creates a service_price.

  ## Examples

      iex> create_service_price(%{field: value})
      {:ok, %ServicePrice{}}

      iex> create_service_price(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_service_price(attrs), do: create_service_price(Organizations.default_shop!(), attrs)

  def create_service_price(%Shop{} = shop, attrs) do
    %ServicePrice{business_id: shop.business_id, shop_id: shop.id}
    |> ServicePrice.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a service_price.

  ## Examples

      iex> update_service_price(service_price, %{field: new_value})
      {:ok, %ServicePrice{}}

      iex> update_service_price(service_price, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_service_price(%ServicePrice{} = service_price, attrs) do
    service_price
    |> ServicePrice.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a service_price.

  ## Examples

      iex> delete_service_price(service_price)
      {:ok, %ServicePrice{}}

      iex> delete_service_price(service_price)
      {:error, %Ecto.Changeset{}}

  """
  def delete_service_price(%ServicePrice{} = service_price) do
    Repo.delete(service_price)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking service_price changes.

  ## Examples

      iex> change_service_price(service_price)
      %Ecto.Changeset{data: %ServicePrice{}}

  """
  def change_service_price(%ServicePrice{} = service_price, attrs \\ %{}) do
    ServicePrice.changeset(service_price, attrs)
  end
end
