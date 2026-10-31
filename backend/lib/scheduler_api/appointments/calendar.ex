defmodule SchedulerApi.Appointments.Calendar do
  @moduledoc "Bounded local-calendar reads; existing complete operational grants remain authoritative."
  alias SchedulerApi.{Authorization, Repo}
  @keys ~w(date days status shop_id limit cursor)
  def read(user, business_id, options) do
    with true <- Enum.all?(Map.keys(options), &(&1 in @keys)),
         {:ok, date} <- date(options["date"]),
         {:ok, days} <- number(Map.get(options, "days", "1"), [1, 7]),
         {:ok, limit} <- number(Map.get(options, "limit", "50"), 1..100),
         {:ok, shop} <- shop(options["shop_id"]),
         status = Map.get(options, "status", "all"),
         true <- status in ~w(all pending confirmed completed cancelled),
         binding = [1, user.id, business_id, shop || 0, Date.to_iso8601(date), days, status],
         {:ok, after_time, after_id} <- cursor(options["cursor"], binding) do
      {scope, values} =
        Repo.to_sql(:all, Authorization.dashboard_shops_query(user, business_id, shop))

      p = fn n -> "$#{length(values) + n}" end

      sql = """
      WITH authorized AS (#{scope}), dates AS (
        SELECT *, #{p.(1)}::date::timestamp AT TIME ZONE timezone AT TIME ZONE 'UTC' AS first,
          (#{p.(1)}::date + #{p.(2)}::integer)::timestamp AT TIME ZONE timezone AT TIME ZONE 'UTC' AS last FROM authorized
      ), page AS (
        SELECT a.*, d.name AS shop_name,d.timezone FROM appointments a JOIN dates d ON d.id=a.shop_id
        WHERE a.starts_at>=d.first AND a.starts_at<d.last
          AND (#{p.(3)}::text IS NULL OR a.status=#{p.(3)}::text)
          AND (#{p.(4)}::timestamptz IS NULL OR (a.starts_at,a.id)>(#{p.(4)}::timestamptz AT TIME ZONE 'UTC',#{p.(5)}::bigint))
        ORDER BY a.starts_at,a.id LIMIT #{p.(6)}::integer
      )
      SELECT (SELECT count(*) FROM authorized), jsonb_build_object(
        'shops',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'timezone',timezone) ORDER BY id),'[]') FROM authorized),
        'appointments',(SELECT coalesce(jsonb_agg(jsonb_build_object(
          'id',a.id,'shop_id',a.shop_id,'shop_name',a.shop_name,'timezone',a.timezone,
          'starts_at',to_char(a.starts_at,'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'ends_at',to_char(a.starts_at+a.duration_minutes*interval '1 minute','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
          'duration_minutes',a.duration_minutes,'service_name',s.name,'vehicle_make',a.vehicle_make,
          'vehicle_model',a.vehicle_model,'vehicle_size',v.name,'status',a.status,
          'crew_size',(SELECT count(*) FROM appointment_assignments j WHERE j.appointment_id=a.id AND j.status='active'),
          'lead_detailer',(SELECT e.first_name || ' ' || e.last_name FROM appointment_assignments j JOIN employments e ON e.id=j.employment_id WHERE j.appointment_id=a.id AND j.status='active' AND j.is_lead LIMIT 1)
        ) ORDER BY a.starts_at,a.id),'[]') FROM page a JOIN service_prices p ON p.id=a.service_price_id
          JOIN services s ON s.id=p.service_id JOIN vehicle_sizes v ON v.id=p.vehicle_size_id))
      """

      params =
        values ++ [date, days, if(status != "all", do: status), after_time, after_id, limit + 1]

      case Repo.query!(sql, params, log: false).rows do
        [[0, _]] ->
          {:error, :forbidden}

        [[_, data]] ->
          rows = Enum.take(data["appointments"], limit)
          more = length(data["appointments"]) > limit

          next =
            if more do
              last = List.last(rows)

              Base.url_encode64(Jason.encode!(binding ++ [last["starts_at"], last["id"]]),
                padding: false
              )
            end

          {:ok,
           Map.merge(data, %{
             "appointments" => rows,
             "meta" => %{
               has_more: more,
               next_cursor: next,
               date: Date.to_iso8601(date),
               days: days
             }
           })}
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp date(v) when is_binary(v) and byte_size(v) == 10, do: Date.from_iso8601(v)
  defp date(_), do: :error

  defp number(v, range) when is_binary(v) and byte_size(v) in 1..3 do
    case Integer.parse(v) do
      {n, ""} -> if n in range, do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp number(_, _), do: :error
  defp shop(nil), do: {:ok, nil}

  defp shop(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> :error
    end
  end

  defp shop(_), do: :error
  defp cursor(nil, _), do: {:ok, nil, 0}

  defp cursor(v, binding) when is_binary(v) and byte_size(v) <= 512 do
    with {:ok, json} <- Base.url_decode64(v, padding: false),
         {:ok, list} when is_list(list) <- Jason.decode(json),
         true <- Enum.take(list, 7) == binding and length(list) == 9,
         time when is_binary(time) <- Enum.at(list, 7),
         {:ok, instant, _} <- DateTime.from_iso8601(time),
         id when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 <- Enum.at(list, 8),
         do: {:ok, instant, id},
         else: (_ -> :error)
  end

  defp cursor(_, _), do: :error
end
