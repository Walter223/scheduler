defmodule SchedulerApi.Appointments.CrewCandidates do
  @moduledoc "Minimal appointment-scoped eligible crew choices. Writes recheck JobAssignments policy."
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Appointments.{Appointment, JobAssignment}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment, WorkShift}
  alias SchedulerApi.Organizations.Shop

  def list(user, %Appointment{} = booking, opts) do
    allowed = Authorization.authorized_shop_ids_query(user, :jobs_assign)

    scope =
      from a in Appointment,
        join: s in subquery(allowed),
        on: s.id == a.shop_id,
        where: a.id == ^booking.id

    with %Appointment{} = booking <- Repo.one(scope),
         {:ok, after_id} <- position(Keyword.get(opts, :cursor), user.id, booking) do
      limit = Keyword.get(opts, :limit, 50)
      ends = DateTime.add(booking.starts_at, (booking.duration_minutes + 30) * 60)

      query =
        from a in ShopAssignment,
          as: :assignment,
          join: e in EmploymentRecord,
          as: :employment,
          on: e.id == a.employment_id and e.business_id == a.business_id,
          join: s in Shop,
          on: s.id == a.shop_id and s.business_id == a.business_id,
          join: permitted in subquery(allowed),
          on: permitted.id == s.id,
          where: a.business_id == ^booking.business_id and a.shop_id == ^booking.shop_id,
          where: a.status == :active and e.status == :active and e.classification == :detailer,
          where: ^(booking.status in [:pending, :confirmed]) and a.id > ^after_id,
          where:
            fragment("(? AT TIME ZONE ?)::date", ^booking.starts_at, s.timezone) >= e.starts_on,
          where:
            fragment("(? AT TIME ZONE ?)::date", ^booking.starts_at, s.timezone) >= a.starts_on,
          where:
            is_nil(e.ends_on) or
              fragment(
                "((?::timestamptz - interval '1 microsecond') AT TIME ZONE ?)::date",
                ^ends,
                s.timezone
              ) <= e.ends_on,
          where:
            is_nil(a.ends_on) or
              fragment(
                "((?::timestamptz - interval '1 microsecond') AT TIME ZONE ?)::date",
                ^ends,
                s.timezone
              ) <= a.ends_on,
          where:
            exists(
              from w in WorkShift,
                where:
                  w.assignment_id == parent_as(:assignment).id and w.status == :active and
                    w.starts_at <= ^booking.starts_at and w.ends_at >= ^ends,
                select: 1
            ),
          where:
            not exists(
              from j in JobAssignment,
                where:
                  j.employment_id == parent_as(:employment).id and
                    j.business_id == ^booking.business_id and j.status == :active and
                    j.starts_at < ^ends and j.ends_at > ^booking.starts_at,
                select: 1
            ),
          order_by: a.id,
          limit: ^(limit + 1),
          select: %{
            assignment_id: a.id,
            employee_id: e.employee_id,
            period_id: e.id,
            first_name: e.first_name,
            last_name: e.last_name
          }

      # Named bindings let correlated eligibility checks remain SQL-scoped before pagination.
      rows = Repo.all(query)
      items = Enum.take(rows, limit)
      more = length(rows) > limit

      cursor =
        if more,
          do:
            Base.url_encode64(
              Jason.encode!([1, user.id, booking.id, List.last(items).assignment_id]),
              padding: false
            )

      {:ok, %{candidates: items, has_more: more, next_cursor: cursor}}
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp position(nil, _, _), do: {:ok, 0}

  defp position(value, actor, booking) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [1, ^actor, appointment, id]} <- Jason.decode(json),
         true <-
           appointment == booking.id and is_integer(id) and id > 0 and
             id <= 9_223_372_036_854_775_807 do
      {:ok, id}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp position(_, _, _), do: {:error, :invalid_input}
end
