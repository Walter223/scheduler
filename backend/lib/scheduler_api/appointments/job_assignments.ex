defmodule SchedulerApi.Appointments.JobAssignments do
  @moduledoc "Audited Detailer jobs. One covering shift is required; public availability is unaffected."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment, WorkShift}
  alias SchedulerApi.Appointments.{Appointment, JobAssignment, JobAssignmentAuditEvent}

  @fields [
    :id,
    :appointment_id,
    :assignment_id,
    :employment_id,
    :business_id,
    :shop_id,
    :work_shift_id,
    :starts_at,
    :ends_at,
    :status,
    :closed_at
  ]

  def assign(credential, appointment, assignment, opts \\ []),
    do: mutate(:assign, credential, appointment, assignment, opts)

  def reassign(credential, appointment, assignment, opts \\ []),
    do: mutate(:reassign, credential, appointment, assignment, opts)

  def unassign(credential, appointment, opts \\ []),
    do: mutate(:unassign, credential, appointment, nil, opts)

  def list_shop_assignments(user, shop, opts \\ [])

  def list_shop_assignments(%User{} = user, %Shop{id: id}, opts) when is_integer(id),
    do: list(user, :jobs_assign, :shop_id, id, opts)

  def list_shop_assignments(_, _, _), do: {:error, :forbidden}

  def list_own_work(user, business, opts \\ [])

  def list_own_work(%User{} = user, %Business{id: id}, opts) when is_integer(id),
    do: list(user, :jobs_assigned_read, :business_id, id, opts)

  def list_own_work(_, _, _), do: {:error, :forbidden}

  defp mutate(action, credential, appointment, assignment, opts) do
    with {:ok, now} <- clock(opts) do
      case Repo.transaction(fn ->
             booking = reference(appointment)

             business =
               if booking, do: RoleManagement.lock_business(%Business{id: booking.business_id})

             actor = lock_actor(credential, business)
             # Same-business sensitive writes serialize here, before authorization recheck.
             authorized =
               actor && booking &&
                 Authorization.authorize(actor.user, :jobs_assign, %Shop{id: booking.shop_id}) ==
                   :ok

             target = if authorized, do: lock_target(booking, assignment)
             outcome = if target, do: change_job(action, target, now), else: {:error, :forbidden}

             {status, reason, job, replacement} =
               case outcome do
                 {:ok, job, replacement} ->
                   {:applied,
                    %{assign: :assigned, reassign: :reassigned, unassign: :unassigned}[action],
                    job, replacement}

                 {:error, reason} ->
                   {:denied, reason, target && target.current, nil}
               end

             event = %JobAssignmentAuditEvent{
               actor_user_id: actor && actor.user.id,
               appointment_id: booking && booking.id,
               business_id: booking && booking.business_id,
               shop_id: booking && booking.shop_id,
               job_id: job && job.id,
               replacement_job_id: replacement && replacement.id,
               action: action,
               outcome: status,
               reason: Atom.to_string(reason),
               occurred_at: now
             }

             persist!(Repo.insert(event, log: false))

             if status == :applied,
               do: {:ok, Map.take(replacement || job, @fields)},
               else: {:error, reason}
           end) do
        {:ok, result} -> result
        {:error, _} -> {:error, :persistence_failed}
      end
    end
  rescue
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :persistence_failed}
  end

  defp change_job(action, t, now) do
    cond do
      action == :assign and t.current ->
        {:error, :already_assigned}

      action != :assign and is_nil(t.current) ->
        {:error, :not_assigned}

      action == :unassign ->
        {:ok, close!(t.current, :unassigned, now), nil}

      t.booking.status not in [:pending, :confirmed] ->
        {:error, :invalid_appointment}

      not eligible?(t) ->
        {:error, :ineligible_detailer}

      t.current && t.current.assignment_id == t.assignment.id ->
        {:error, :unchanged}

      overlap?(t) ->
        {:error, :overlap}

      is_nil(t.shift) ->
        {:error, :missing_covering_shift}

      true ->
        old = if t.current, do: close!(t.current, :reassigned, now)

        job =
          persist!(
            Repo.insert(
              %JobAssignment{
                appointment_id: t.booking.id,
                business_id: t.booking.business_id,
                shop_id: t.booking.shop_id,
                employment_id: t.employment.id,
                assignment_id: t.assignment.id,
                work_shift_id: t.shift.id,
                starts_at: t.booking.starts_at,
                ends_at: t.ends_at,
                inserted_at: now
              },
              log: false
            )
          )

        if old, do: {:ok, old, job}, else: {:ok, job, nil}
    end
  end

  defp reference(%Appointment{id: id}) when is_integer(id), do: Repo.get(Appointment, id)
  defp reference(_), do: nil

  defp lock_target(booking, ref) do
    current =
      Repo.one(
        from j in JobAssignment, where: j.appointment_id == ^booking.id and j.status == :active
      )

    assignment =
      case ref do
        %ShopAssignment{id: id} when is_integer(id) -> Repo.get(ShopAssignment, id)
        _ -> nil
      end

    assignment =
      if assignment && assignment.business_id == booking.business_id &&
           assignment.shop_id == booking.shop_id,
         do: assignment

    # Business -> actor -> employments (ascending) -> assignments -> shop -> shifts
    # -> appointment -> job. WorkSchedules shares this parent-first order. No
    # appointment booking advisory lock is changed or acquired in the reverse order.
    ids =
      Enum.uniq(
        Enum.reject(
          [assignment && assignment.employment_id, current && current.employment_id],
          &is_nil/1
        )
      )

    workers =
      Repo.all(
        from e in EmploymentRecord, where: e.id in ^ids, order_by: e.id, lock: "FOR UPDATE"
      )

    assignment_ids =
      Enum.uniq(
        Enum.reject([assignment && assignment.id, current && current.assignment_id], &is_nil/1)
      )

    Repo.all(
      from a in ShopAssignment, where: a.id in ^assignment_ids, order_by: a.id, lock: "FOR SHARE"
    )

    assignment = if assignment, do: Repo.get!(ShopAssignment, assignment.id)
    shop = Repo.one!(from s in Shop, where: s.id == ^booking.shop_id, lock: "FOR SHARE")
    ends_at = DateTime.add(booking.starts_at, (booking.duration_minutes + 30) * 60)

    shift =
      if assignment do
        Repo.one(
          from w in WorkShift,
            where:
              w.assignment_id == ^assignment.id and w.business_id == ^booking.business_id and
                w.shop_id == ^booking.shop_id and w.status == :active and
                w.starts_at <= ^booking.starts_at and w.ends_at >= ^ends_at,
            order_by: w.id,
            limit: 1,
            lock: "FOR SHARE"
        )
      end

    booking = Repo.one!(from a in Appointment, where: a.id == ^booking.id, lock: "FOR UPDATE")

    # A future appointment mutation must not leave us using the earlier read's
    # occupied period. Database source guards independently protect existing jobs.
    if booking.business_id != shop.business_id or booking.shop_id != shop.id,
      do: Repo.rollback(:persistence_failed)

    ends_at = DateTime.add(booking.starts_at, (booking.duration_minutes + 30) * 60)

    shift =
      if shift && DateTime.compare(shift.starts_at, booking.starts_at) != :gt &&
           DateTime.compare(shift.ends_at, ends_at) != :lt,
         do: shift

    current =
      if current,
        do: Repo.one!(from j in JobAssignment, where: j.id == ^current.id, lock: "FOR UPDATE")

    %{
      booking: booking,
      assignment: assignment,
      employment: Enum.find(workers, &(assignment && &1.id == assignment.employment_id)),
      shop: shop,
      shift: shift,
      current: current,
      ends_at: ends_at
    }
  end

  defp eligible?(%{employment: nil}), do: false

  defp eligible?(t) do
    e = t.employment
    a = t.assignment

    %{rows: [[first, last]]} =
      Repo.query!(
        "SELECT ($1::timestamptz AT TIME ZONE $3)::date, (($2::timestamptz - interval '1 microsecond') AT TIME ZONE $3)::date",
        [t.booking.starts_at, t.ends_at, t.shop.timezone],
        log: false
      )

    e.status == :active and e.classification == :detailer and a.status == :active and
      e.business_id == t.booking.business_id and a.business_id == t.booking.business_id and
      a.shop_id == t.booking.shop_id and
      Date.compare(first, e.starts_on) != :lt and Date.compare(first, a.starts_on) != :lt and
      (is_nil(e.ends_on) or Date.compare(last, e.ends_on) != :gt) and
      (is_nil(a.ends_on) or Date.compare(last, a.ends_on) != :gt)
  end

  defp overlap?(t) do
    ignore = (t.current && t.current.id) || 0

    Repo.exists?(
      from j in JobAssignment,
        where:
          j.employment_id == ^t.employment.id and
            j.business_id == ^t.booking.business_id and j.status == :active and j.id != ^ignore and
            j.starts_at < ^t.ends_at and j.ends_at > ^t.booking.starts_at
    )
  end

  defp close!(job, status, now),
    do:
      persist!(
        Repo.update(Ecto.Changeset.change(job, status: status, closed_at: now), log: false)
      )

  defp persist!({:ok, value}), do: value
  defp persist!({:error, _}), do: Repo.rollback(:persistence_failed)

  defp lock_actor(%SessionCredential{} = credential, business) do
    token = SessionCredential.reveal(credential)

    with {:ok, session} <- Accounts.get_session_by_token(token) do
      Repo.one(from u in User, where: u.id == ^session.user_id, lock: "FOR UPDATE")
      Repo.one(from s in WebSession, where: s.id == ^session.id, lock: "FOR UPDATE")

      if business do
        member =
          Repo.one(
            from m in BusinessMembership,
              where: m.user_id == ^session.user_id and m.business_id == ^business.id,
              lock: "FOR SHARE"
          )

        if member,
          do:
            Repo.all(
              from r in RoleAssignment,
                where: r.membership_id == ^member.id,
                order_by: r.id,
                lock: "FOR SHARE"
            )
      end

      case Accounts.get_session_by_token(token) do
        {:ok, current} -> current
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp lock_actor(_, _), do: nil

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :now)),
      do: SchedulerApi.Authentication.now(opts),
      else: {:error, :invalid_options}
  end

  defp clock(_), do: {:error, :invalid_options}

  defp list(user, action, field, id, opts) do
    scopes =
      from p in subquery(Authorization.job_scopes_query(user, action)),
        where: field(p, ^field) == ^id

    with true <- Repo.exists?(scopes), {:ok, limit, cursor} <- list_options(opts) do
      allowed = Authorization.authorized_job_assignment_ids_query(user, action)

      query =
        from j in JobAssignment,
          join: p in subquery(allowed),
          on: p.id == j.id,
          where: field(j, ^field) == ^id,
          order_by: [asc: j.starts_at, asc: j.id],
          limit: ^(limit + 1)

      query =
        case cursor do
          nil ->
            query

          {at, last_id} ->
            where(query, [j], j.starts_at > ^at or (j.starts_at == ^at and j.id > ^last_id))
        end

      rows = Repo.all(from j in query, select: map(j, ^@fields))
      jobs = Enum.take(rows, limit)
      has_more = length(rows) > limit

      next =
        if has_more do
          last = List.last(jobs)

          Base.url_encode64(Jason.encode!([1, DateTime.to_iso8601(last.starts_at), last.id]),
            padding: false
          )
        end

      {:ok, %{assignments: jobs, has_more: has_more, next_cursor: next}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp list_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :cursor])) do
      with limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 50),
           {:ok, cursor} <- cursor(Keyword.get(opts, :cursor)) do
        {:ok, limit, cursor}
      else
        _ -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp list_options(_), do: {:error, :invalid_options}
  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [1, start, id]} <- Jason.decode(json),
         {:ok, instant} <- WorkShift.instant(start),
         true <- is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 do
      {:ok, {instant, id}}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp cursor(_), do: {:error, :invalid_options}
end
