defmodule SchedulerApi.Appointments.Availability do
  @moduledoc """
  Availability for one shared detailing schedule per shop in America/Denver.

  PostgreSQL's IANA timezone database handles local dates and DST. Stored
  appointment timestamps remain UTC. Occupied periods are half-open intervals:
  [start, start + snapshotted duration + 30 minutes).
  """

  import Ecto.Query
  alias SchedulerApi.{Repo, Catalog, Organizations}
  alias SchedulerApi.Organizations.Shop
  alias SchedulerApi.Appointments.Appointment

  @buffer_minutes 30
  @booking_days 90

  @doc "Returns local HH:MM start times. The optional clock supports deterministic tests."
  def get(date, service_price_id, now \\ DateTime.utc_now()),
    do: get_for_shop(Organizations.default_shop!(), date, service_price_id, now)

  def get_for_shop(%Shop{} = shop, date, service_price_id, now \\ DateTime.utc_now()) do
    with {:ok, date} <- parse_date(date),
         :ok <- validate_date(date, now),
         {:ok, id} <- parse_id(service_price_id),
         {:ok, price} <- fetch_price(shop, id) do
      {opens, _} = business_hours(date)

      {:ok,
       %{
         date: Date.to_iso8601(date),
         service_price_id: price.id,
         duration_minutes: price.duration_minutes,
         available_times:
           shop
           |> slots(date, price.duration_minutes, now)
           |> Enum.map(fn start ->
             ~T[09:00:00]
             |> Time.add(DateTime.diff(start, opens, :second), :second)
             |> Calendar.strftime("%H:%M")
           end)
       }}
    end
  end

  @doc "Revalidates a UTC appointment start using the trusted catalog duration."
  def validate_slot(starts_at, duration_minutes, now \\ DateTime.utc_now()),
    do: validate_slot_for_shop(Organizations.default_shop!(), starts_at, duration_minutes, now)

  def validate_slot_for_shop(
        %Shop{} = shop,
        starts_at,
        duration_minutes,
        now \\ DateTime.utc_now()
      ) do
    date = starts_at |> local_datetime() |> NaiveDateTime.to_date()

    with :ok <- validate_date(date, now) do
      if Enum.any?(
           slots(shop, date, duration_minutes, now),
           &(DateTime.compare(&1, starts_at) == :eq)
         ) do
        :ok
      else
        error(:starts_at, :unavailable, "is not an available start time")
      end
    end
  end

  @doc "Converts an instant to Denver wall time using PostgreSQL timezone rules."
  def local_datetime(%DateTime{} = instant) do
    %{rows: [[local]]} =
      Repo.query!("SELECT $1::timestamptz AT TIME ZONE 'America/Denver'", [instant])

    local
  end

  @doc "Returns UTC opening and closing instants for a Denver calendar date."
  def business_hours(%Date{} = date) do
    %{rows: [[opens, closes]]} =
      Repo.query!(
        """
        SELECT ($1::date + time '09:00') AT TIME ZONE 'America/Denver',
               ($1::date + time '18:00') AT TIME ZONE 'America/Denver'
        """,
        [date]
      )

    {DateTime.truncate(opens, :second), DateTime.truncate(closes, :second)}
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:ok, date}
      _ -> error(:date, :invalid_date, "must be a valid ISO date (YYYY-MM-DD)")
    end
  end

  defp parse_date(_), do: error(:date, :invalid_date, "must be a valid ISO date (YYYY-MM-DD)")

  defp validate_date(date, now) do
    today = now |> local_datetime() |> NaiveDateTime.to_date()
    days = Date.diff(date, today)

    cond do
      days < 0 -> error(:date, :past_date, "must not be in the past")
      days > @booking_days -> error(:date, :outside_booking_window, "must be within 90 days")
      Date.day_of_week(date) == 7 -> error(:date, :closed_sunday, "we are closed on Sundays")
      true -> :ok
    end
  end

  # Limit IDs to the PostgreSQL bigint range before issuing a query.
  defp parse_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> parse_id(id)
      _ -> error(:service_price_id, :invalid_service_price_id, "must be a positive integer")
    end
  end

  defp parse_id(_),
    do: error(:service_price_id, :invalid_service_price_id, "must be a positive integer")

  defp fetch_price(shop, id) do
    case Repo.one(from p in Catalog.service_price_query(shop), where: p.id == ^id) do
      nil -> error(:service_price_id, :not_found, "service price does not exist")
      price -> {:ok, price}
    end
  end

  defp slots(shop, date, duration, now) do
    {opens, closes} = business_hours(date)
    appointments = blocking_appointments(shop, opens, closes)

    for offset <- 0..510//30,
        start = DateTime.add(opens, offset * 60, :second),
        finish = occupied_until(start, duration),
        DateTime.compare(start, now) == :gt,
        DateTime.compare(finish, closes) != :gt,
        not Enum.any?(appointments, &overlap?(start, finish, &1)),
        do: start
  end

  defp blocking_appointments(shop, opens, closes) do
    Repo.all(
      from a in Appointment,
        where: a.shop_id == ^shop.id and a.business_id == ^shop.business_id,
        where: a.status in [:pending, :confirmed],
        where: a.starts_at < ^closes,
        where:
          fragment(
            "? + (? * interval '1 minute') + interval '30 minutes' > ?",
            a.starts_at,
            a.duration_minutes,
            type(^opens, :utc_datetime)
          )
    )
  end

  defp overlap?(start, finish, existing) do
    DateTime.compare(start, occupied_until(existing.starts_at, existing.duration_minutes)) == :lt and
      DateTime.compare(existing.starts_at, finish) == :lt
  end

  defp occupied_until(start, duration),
    do: DateTime.add(start, (duration + @buffer_minutes) * 60, :second)

  defp error(field, code, message), do: {:error, %{field: field, code: code, message: message}}
end
