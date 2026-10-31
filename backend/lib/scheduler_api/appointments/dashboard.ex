defmodule SchedulerApi.Appointments.Dashboard do
  @moduledoc "Single-statement, current-grant operational snapshot with per-shop local dates."
  alias SchedulerApi.{Authorization, Repo}

  def read(user, business_id, shop_id, now \\ DateTime.utc_now()) do
    {scope, params} =
      Repo.to_sql(:all, Authorization.dashboard_shops_query(user, business_id, shop_id))

    clock = "$#{length(params) + 1}::timestamptz"

    sql = """
    WITH authorized AS (#{scope}), days AS (
      SELECT *, (#{clock} AT TIME ZONE timezone)::date AS local_date,
        date_trunc('day', #{clock} AT TIME ZONE timezone) AT TIME ZONE timezone AS first,
        (date_trunc('day', #{clock} AT TIME ZONE timezone) + interval '1 day') AT TIME ZONE timezone AS last
      FROM authorized
    ), today AS (
      SELECT a.*, d.name AS shop_name, d.timezone FROM appointments a JOIN days d ON d.id=a.shop_id
      WHERE a.starts_at >= d.first AND a.starts_at < d.last
    ), teams AS (
      SELECT j.appointment_id, count(*) AS crew_size,
        max(CASE WHEN j.is_lead THEN e.first_name || ' ' || e.last_name END) AS lead_detailer
      FROM appointment_assignments j JOIN today a ON a.id=j.appointment_id
      JOIN employments e ON e.id=j.employment_id AND e.business_id=j.business_id
      WHERE j.status='active' GROUP BY j.appointment_id
    ), shifts AS (
      SELECT w.id, e.employee_id, e.classification FROM work_shifts w
      JOIN days d ON d.id=w.shop_id JOIN employments e ON e.id=w.employment_id AND e.business_id=w.business_id
      JOIN employment_shop_assignments sa ON sa.id=w.assignment_id AND sa.business_id=w.business_id
      WHERE w.status='active' AND w.starts_at < d.last AND w.ends_at > d.first
        AND e.status='active' AND sa.status='active' AND e.starts_on <= d.local_date AND sa.starts_on <= d.local_date
    )
    SELECT (SELECT count(*) FROM days), jsonb_build_object(
      'shops', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'timezone',timezone,'date',local_date) ORDER BY id),'[]') FROM days),
      'metrics', jsonb_build_object(
        'appointments', (SELECT count(*) FROM today WHERE status <> 'cancelled'),
        'unassigned', (SELECT count(*) FROM today a LEFT JOIN teams t ON t.appointment_id=a.id WHERE a.status IN ('pending','confirmed') AND coalesce(t.crew_size,0)=0),
        'detailers', (SELECT count(DISTINCT employee_id) FROM shifts WHERE classification='detailer'),
        'shifts', (SELECT count(*) FROM shifts)),
      'appointments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id',a.id,'shop_name',a.shop_name,'timezone',a.timezone,'starts_at',a.starts_at,
        'duration_minutes',a.duration_minutes,'status',a.status,'service_name',s.name,
        'crew_size',coalesce(t.crew_size,0),'lead_detailer',t.lead_detailer
      ) ORDER BY a.starts_at,a.id),'[]') FROM today a
        JOIN service_prices p ON p.id=a.service_price_id JOIN services s ON s.id=p.service_id
        LEFT JOIN teams t ON t.appointment_id=a.id))
    """

    case Repo.query!(sql, params ++ [now], log: false).rows do
      [[0, _]] -> {:error, :forbidden}
      [[_, data]] -> {:ok, data}
    end
  end
end
