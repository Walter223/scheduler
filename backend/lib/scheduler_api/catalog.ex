defmodule SchedulerApi.Catalog do
  @moduledoc """
  The Catalog context.
  """

  import Ecto.Query, warn: false
  alias SchedulerApi.Repo

  alias SchedulerApi.Catalog.Service

  @doc """
  Returns the list of services.

  ## Examples

      iex> list_services()
      [%Service{}, ...]

  """
  def list_services do
    Repo.all(Service)
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
  def get_service!(id), do: Repo.get!(Service, id)

  @doc """
  Creates a service.

  ## Examples

      iex> create_service(%{field: value})
      {:ok, %Service{}}

      iex> create_service(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_service(attrs) do
    %Service{}
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
    Repo.all(VehicleSize)
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
  def get_vehicle_size!(id), do: Repo.get!(VehicleSize, id)

  @doc """
  Creates a vehicle_size.

  ## Examples

      iex> create_vehicle_size(%{field: value})
      {:ok, %VehicleSize{}}

      iex> create_vehicle_size(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vehicle_size(attrs) do
    %VehicleSize{}
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
  def list_service_prices do
    Repo.all(ServicePrice)
  end

  @doc """
  Gets a single service_price.

  Raises `Ecto.NoResultsError` if the Service price does not exist.

  ## Examples

      iex> get_service_price!(123)
      %ServicePrice{}

      iex> get_service_price!(456)
      ** (Ecto.NoResultsError)

  """
  def get_service_price!(id), do: Repo.get!(ServicePrice, id)

  @doc """
  Creates a service_price.

  ## Examples

      iex> create_service_price(%{field: value})
      {:ok, %ServicePrice{}}

      iex> create_service_price(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_service_price(attrs) do
    %ServicePrice{}
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
