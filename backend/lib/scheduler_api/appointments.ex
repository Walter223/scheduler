defmodule SchedulerApi.Appointments do
  @moduledoc """
  Creates and retrieves appointments using catalog price and duration snapshots.
  """

  import Ecto.Query

  alias SchedulerApi.{Repo, Catalog, Organizations}
  alias SchedulerApi.Organizations.Shop
  alias SchedulerApi.Appointments.{Appointment, Availability}

  @shop_schedule_namespace -1

  @doc """
  Returns appointments ordered by start time and ID.
  """
  def list_appointments, do: list_appointments(Organizations.default_shop!())

  def list_appointments(%Shop{} = shop) do
    Repo.all(
      from a in Appointment,
        where: a.shop_id == ^shop.id and a.business_id == ^shop.business_id,
        order_by: [asc: a.starts_at, asc: a.id]
    )
  end

  @doc """
  Lists upcoming pending/confirmed appointments with their catalog associations.

  Options are a keyword list: `:limit` (integer 1..100, default 50), `:cursor`
  (an opaque token returned by the previous page, default nil), and `:now`
  (a DateTime, default UTC now captured once). The clock is normalized to UTC
  and truncated to seconds; starts exactly at that instant are included.

  Returns `{:ok, %{appointments: [...], has_more: boolean, next_cursor: token_or_nil}}`
  or `{:error, %{field: atom, message: string}}` for invalid options.
  The cursor is an unsigned, URL-safe encoding of the last `(starts_at, id)`;
  it identifies a position, not an authorization credential or frozen snapshot.
  Pass the same `:now` on subsequent pages when a fixed cutoff is desired.

  No availability rules or catalog price/duration replacements are applied.
  Default wrappers resolve the public Magnum shop; explicit Shop arguments are
  trusted server-side boundaries, not authorization or accepted HTTP ownership.
  """
  def list_upcoming_appointments(opts \\ []),
    do: list_upcoming_appointments(Organizations.default_shop!(), opts)

  def list_upcoming_appointments(%Shop{} = shop, opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      with {:ok, limit} <- upcoming_limit(Keyword.get(opts, :limit, 50)),
           {:ok, cursor} <- upcoming_cursor(Keyword.get(opts, :cursor)),
           {:ok, now} <- upcoming_now(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)) do
        query =
          from a in Appointment,
            where: a.shop_id == ^shop.id and a.business_id == ^shop.business_id,
            where: a.starts_at >= ^now and a.status in [:pending, :confirmed],
            order_by: [asc: a.starts_at, asc: a.id],
            limit: ^(limit + 1),
            preload: [service_price: [:service, :vehicle_size]]

        rows = query |> after_upcoming_cursor(cursor) |> Repo.all()
        appointments = Enum.take(rows, limit)
        has_more = length(rows) > limit
        next_cursor = if has_more, do: encode_upcoming_cursor(List.last(appointments))

        {:ok, %{appointments: appointments, has_more: has_more, next_cursor: next_cursor}}
      end
    else
      {:error, %{field: :options, message: "must be a keyword list"}}
    end
  end

  defp upcoming_limit(limit) when is_integer(limit) and limit >= 1 and limit <= 100,
    do: {:ok, limit}

  defp upcoming_limit(_),
    do: {:error, %{field: :limit, message: "must be an integer from 1 to 100"}}

  defp upcoming_now(%DateTime{} = now) do
    {:ok, now |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)}
  end

  defp upcoming_now(_), do: {:error, %{field: :now, message: "must be a DateTime"}}

  defp upcoming_cursor(nil), do: {:ok, nil}

  defp upcoming_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 512 do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, timestamp, id]} <- Jason.decode(decoded),
         true <- is_binary(timestamp),
         true <- is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
         {:ok, starts_at, _offset} <- DateTime.from_iso8601(timestamp),
         {0, _precision} <- starts_at.microsecond do
      {:ok, {DateTime.truncate(starts_at, :second), id}}
    else
      _ -> invalid_upcoming_cursor()
    end
  end

  defp upcoming_cursor(_), do: invalid_upcoming_cursor()

  defp invalid_upcoming_cursor,
    do: {:error, %{field: :cursor, message: "must be a valid upcoming-appointments cursor"}}

  defp encode_upcoming_cursor(appointment) do
    [1, DateTime.to_iso8601(appointment.starts_at), appointment.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp after_upcoming_cursor(query, nil), do: query

  defp after_upcoming_cursor(query, {starts_at, id}) do
    from a in query,
      where: a.starts_at > ^starts_at or (a.starts_at == ^starts_at and a.id > ^id)
  end

  @doc """
  Returns an appointment, or nil when absent.
  """
  def get_appointment(id), do: get_appointment(Organizations.default_shop!(), id)

  def get_appointment(%Shop{} = shop, id),
    do:
      Repo.one(
        from a in Appointment,
          where: a.id == ^id and a.shop_id == ^shop.id and a.business_id == ^shop.business_id
      )

  @doc """
  Returns an appointment or raises Ecto.NoResultsError.
  """
  def get_appointment!(id), do: get_appointment!(Organizations.default_shop!(), id)

  def get_appointment!(%Shop{} = shop, id),
    do:
      Repo.one!(
        from a in Appointment,
          where: a.id == ^id and a.shop_id == ^shop.id and a.business_id == ^shop.business_id
      )

  @doc """
  Creates a pending appointment.

  Customer-supplied price, duration, and status are ignored.

  A transaction-level advisory lock serializes creation for the selected shop
  before availability is rechecked and the appointment is inserted. The PostgreSQL
  exclusion constraint remains the final overlap safety net, including buffers.

  Price and duration are copied from the selected service price and stored
  on the appointment as historical snapshots.
  """
  def create_appointment(attrs), do: create_appointment(Organizations.default_shop!(), attrs)

  def create_appointment(%Shop{} = shop, attrs) do
    input_changeset =
      Appointment.input_changeset(%Appointment{}, attrs)

    if input_changeset.valid? do
      create_from_service_price(shop, input_changeset, attrs)
    else
      {:error, input_changeset}
    end
  end

  defp create_from_service_price(shop, input_changeset, attrs) do
    service_price_id =
      Ecto.Changeset.get_field(
        input_changeset,
        :service_price_id
      )

    Repo.transaction(fn ->
      # Reserve the negative single-bigint advisory-key namespace for scheduling:
      # key = -shop.id is collision-free for every positive PostgreSQL bigint ID.
      # PostgreSQL's two-int form only accepts 32-bit IDs; no truncation/hash is used.
      # Acquire before catalog row locks and the authoritative availability check.
      # Transaction lifetime applies to every caller, including future platform staff.
      Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [@shop_schedule_namespace * shop.id])

      service_price =
        Repo.one(
          from price in Catalog.service_price_query(shop),
            where: price.id == ^service_price_id,
            lock: "FOR SHARE"
        )

      case service_price do
        nil ->
          input_changeset
          |> Ecto.Changeset.add_error(
            :service_price_id,
            "does not exist"
          )
          |> Repo.rollback()

        service_price ->
          insert_appointment(shop, service_price, attrs)
      end
    end)
  end

  defp insert_appointment(shop, service_price, attrs) do
    # Ownership always comes from the shop-validated, locked catalog row.
    appointment =
      %Appointment{
        business_id: service_price.business_id,
        shop_id: service_price.shop_id,
        price_cents: service_price.price_cents,
        duration_minutes: service_price.duration_minutes
      }

    changeset =
      Appointment.changeset(
        appointment,
        attrs
      )

    starts_at = Ecto.Changeset.get_field(changeset, :starts_at)

    case Availability.validate_slot_for_shop(shop, starts_at, service_price.duration_minutes) do
      :ok ->
        :ok

      {:error, error} ->
        changeset
        |> Ecto.Changeset.add_error(:starts_at, error.message)
        |> Repo.rollback()
    end

    # Keep the exclusion constraint as defense in depth, including for writes
    # that bypass this context and its shared scheduling lock.
    case Repo.insert(changeset) do
      {:ok, appointment} ->
        appointment

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end
end
