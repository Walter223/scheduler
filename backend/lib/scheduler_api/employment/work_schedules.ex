defmodule SchedulerApi.Employment.WorkSchedules do
  @moduledoc "Audited employee work shifts, independent of appointment capacity/availability."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment, WorkShift, WorkShiftAuditEvent}

  @fields [
    :id,
    :assignment_id,
    :employment_id,
    :business_id,
    :shop_id,
    :starts_at,
    :ends_at,
    :timezone,
    :status,
    :supersedes_id,
    :closed_at
  ]

  def create_shift(credential, assignment, attrs, opts \\ []),
    do: mutate(:create, credential, assignment, attrs, opts)

  def cancel_shift(credential, shift, opts \\ []),
    do: mutate(:cancel, credential, shift, %{}, opts)

  def reschedule_shift(credential, shift, attrs, opts \\ []),
    do: mutate(:reschedule, credential, shift, attrs, opts)

  @doc "Convert an explicit shop-local wall time AND chosen UTC offset; reject gaps/incorrect offsets."
  def local_to_utc(%Shop{id: id}, %NaiveDateTime{microsecond: {0, _}} = local, offset)
      when is_integer(id) and is_integer(offset) and offset in -50400..50400 do
    shop = Repo.one(from s in Shop, where: s.id == ^id, select: %{timezone: s.timezone})

    cond do
      is_nil(shop) ->
        {:error, :invalid_shop}

      not valid_timezone?(shop.timezone) ->
        {:error, :invalid_timezone}

      true ->
        utc = local |> NaiveDateTime.add(-offset, :second) |> DateTime.from_naive!("Etc/UTC")

        %{rows: [[roundtrip]]} =
          Repo.query!("SELECT $1::timestamptz AT TIME ZONE $2", [utc, shop.timezone], log: false)

        if NaiveDateTime.compare(roundtrip, local) == :eq,
          do: {:ok, utc},
          else: {:error, :invalid_local_time}
    end
  end

  def local_to_utc(_, _, _), do: {:error, :invalid_local_time}

  @doc "Manager history at an authorized shop, with scope applied before pagination."
  def list_shop_shifts(user, shop, opts \\ [])

  def list_shop_shifts(%User{} = user, %Shop{id: id}, opts) when is_integer(id),
    do: list(user, :schedule_manage, {:shop_id, id}, opts)

  def list_shop_shifts(_, _, _), do: {:error, :forbidden}

  @doc "Only the caller's explicitly linked shifts at matching active employment/shop assignments."
  def list_own_shifts(user, business, opts \\ [])

  def list_own_shifts(%User{} = user, %Business{id: id}, opts) when is_integer(id),
    do: list(user, :schedule_own_read, {:business_id, id}, opts)

  def list_own_shifts(_, _, _), do: {:error, :forbidden}

  def get_shift(user, %WorkShift{id: id}) when is_integer(id) do
    manage = Authorization.authorized_work_shift_ids_query(user, :schedule_manage)
    own = Authorization.authorized_work_shift_ids_query(user, :schedule_own_read)

    query =
      from w in WorkShift,
        where:
          w.id == ^id and
            (w.id in subquery(from p in subquery(manage), select: p.id) or
               w.id in subquery(from p in subquery(own), select: p.id))

    case Repo.one(project(query)) do
      nil -> {:error, :forbidden}
      shift -> {:ok, shift}
    end
  end

  def get_shift(_, _), do: {:error, :forbidden}

  defp mutate(action, credential, ref, attrs, opts) do
    with {:ok, now} <- clock(opts) do
      result =
        Repo.transaction(fn ->
          reference = reference(action, ref)

          business =
            if reference, do: RoleManagement.lock_business(%Business{id: reference.business_id})

          actor = lock_actor(credential, business)
          target = if reference, do: lock_target(reference, action)

          outcome =
            cond do
              is_nil(target) or is_nil(actor) or
                  Authorization.authorize(actor.user, :schedule_manage, %Shop{id: target.shop_id}) !=
                    :ok ->
                {:error, :forbidden}

              action != :create and target.shift.status != :active ->
                {:error, :not_active}

              action == :cancel ->
                closed = update!(WorkShift.close_changeset(target.shift, :cancelled, now))
                {:ok, closed, nil}

              true ->
                prepare_shift(target, action, attrs, now)
            end

          {status, reason, shift, replacement} =
            case outcome do
              {:ok, shift, replacement} ->
                {:applied,
                 %{create: :created, cancel: :cancelled, reschedule: :rescheduled}[action], shift,
                 replacement}

              {:error, reason} ->
                {:denied, reason, target && target.shift, nil}
            end

          metadata =
            if target,
              do: Map.take(target, [:assignment_id, :employment_id, :business_id, :shop_id]),
              else: %{}

          event =
            struct!(
              WorkShiftAuditEvent,
              Map.merge(metadata, %{
                actor_user_id: actor && actor.user.id,
                action: action,
                outcome: status,
                reason: reason,
                shift_id: shift && shift.id,
                replacement_shift_id: replacement && replacement.id,
                occurred_at: now
              })
            )

          case Repo.insert(event, log: false) do
            {:ok, _} ->
              if status == :applied,
                do: {:ok, Map.take(replacement || shift, @fields)},
                else: {:error, reason}

            {:error, _} ->
              Repo.rollback(:persistence_failed)
          end
        end)

      case result do
        {:ok, outcome} -> outcome
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

  defp prepare_shift(t, action, attrs, now) do
    candidate = %WorkShift{
      assignment_id: t.assignment_id,
      employment_id: t.employment_id,
      business_id: t.business_id,
      shop_id: t.shop_id,
      timezone: t.shop.timezone,
      inserted_at: now,
      supersedes_id: t.shift && t.shift.id
    }

    cs = WorkShift.creation_changeset(candidate, attrs)
    proposed = Ecto.Changeset.apply_changes(cs)

    cond do
      not cs.valid? ->
        {:error, :invalid_input}

      not eligible?(t, proposed) ->
        {:error, :ineligible_assignment}

      t.shift && t.shift.starts_at == proposed.starts_at && t.shift.ends_at == proposed.ends_at ->
        {:error, :unchanged}

      overlaps?(proposed, t.shift && t.shift.id) ->
        {:error, :overlap}

      true ->
        previous =
          if action == :reschedule,
            do: update!(WorkShift.close_changeset(t.shift, :superseded, now))

        new = insert!(cs)
        if previous, do: {:ok, previous, new}, else: {:ok, new, nil}
    end
  end

  defp eligible?(t, w) do
    if t.employment.status == :active and t.assignment.status == :active and
         t.shop.status == :active and valid_timezone?(t.shop.timezone) do
      %{rows: [[first, last]]} =
        Repo.query!(
          "SELECT ($1::timestamptz AT TIME ZONE $3)::date, (($2::timestamptz - interval '1 microsecond') AT TIME ZONE $3)::date",
          [w.starts_at, w.ends_at, t.shop.timezone],
          log: false
        )

      Date.compare(first, t.employment.starts_on) != :lt and
        Date.compare(first, t.assignment.starts_on) != :lt and
        (is_nil(t.employment.ends_on) or Date.compare(last, t.employment.ends_on) != :gt) and
        (is_nil(t.assignment.ends_on) or Date.compare(last, t.assignment.ends_on) != :gt)
    else
      false
    end
  end

  defp overlaps?(w, ignore) do
    ignore = ignore || 0

    Repo.exists?(
      from other in WorkShift,
        where:
          other.business_id == ^w.business_id and
            other.employment_id == ^w.employment_id and other.status == :active and
            other.id != ^ignore and
            other.starts_at < ^w.ends_at and other.ends_at > ^w.starts_at
    )
  end

  defp reference(:create, %ShopAssignment{id: id}) when is_integer(id),
    do:
      Repo.one(
        from a in ShopAssignment,
          where: a.id == ^id,
          select: %{
            assignment_id: a.id,
            employment_id: a.employment_id,
            business_id: a.business_id,
            shop_id: a.shop_id,
            shift_id: fragment("NULL::bigint")
          }
      )

  defp reference(action, %WorkShift{id: id})
       when action in [:cancel, :reschedule] and is_integer(id),
       do:
         Repo.one(
           from w in WorkShift,
             where: w.id == ^id,
             select: %{
               assignment_id: w.assignment_id,
               employment_id: w.employment_id,
               business_id: w.business_id,
               shop_id: w.shop_id,
               shift_id: w.id
             }
         )

  defp reference(_, _), do: nil

  defp lock_target(ref, action) do
    # Business -> actor user/session/membership/grants -> employment -> assignment
    # -> shop -> shift. Matches compensation, role management and employment endings.
    e =
      Repo.one(
        from e in EmploymentRecord,
          where: e.id == ^ref.employment_id,
          lock: "FOR UPDATE",
          select: struct(e, [:id, :status, :starts_on, :ends_on])
      )

    a = Repo.one(from a in ShopAssignment, where: a.id == ^ref.assignment_id, lock: "FOR SHARE")
    s = Repo.one(from s in Shop, where: s.id == ^ref.shop_id, lock: "FOR SHARE")

    w =
      if action != :create,
        do: Repo.one(from w in WorkShift, where: w.id == ^ref.shift_id, lock: "FOR UPDATE")

    if e && a && s && (action == :create or not is_nil(w)),
      do: Map.merge(ref, %{employment: e, assignment: a, shop: s, shift: w})
  end

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

  defp valid_timezone?(zone),
    do: Repo.exists?(from z in "pg_timezone_names", where: z.name == ^zone)

  defp insert!(cs), do: persist(Repo.insert(cs, log: false))
  defp update!(cs), do: persist(Repo.update(cs, log: false))
  defp persist({:ok, value}), do: value
  defp persist({:error, _}), do: Repo.rollback(:persistence_failed)

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :now)),
      do: SchedulerApi.Authentication.now(opts),
      else: {:error, :invalid_options}
  end

  defp clock(_), do: {:error, :invalid_options}

  defp list(user, action, {field, id}, opts) do
    scopes =
      from p in subquery(Authorization.work_shift_scopes_query(user, action)),
        where: field(p, ^field) == ^id

    with true <- Repo.exists?(scopes), {:ok, options} <- list_options(opts) do
      allowed = Authorization.authorized_work_shift_ids_query(user, action)

      query =
        from w in WorkShift,
          join: p in subquery(allowed),
          on: p.id == w.id,
          where: field(w, ^field) == ^id,
          order_by: [asc: w.starts_at, asc: w.id],
          limit: ^(options.limit + 1)

      query = if options.from, do: where(query, [w], w.ends_at > ^options.from), else: query
      query = if options.until, do: where(query, [w], w.starts_at < ^options.until), else: query

      query =
        case options.cursor do
          nil ->
            query

          {start, cursor_id} ->
            where(
              query,
              [w],
              w.starts_at > ^start or (w.starts_at == ^start and w.id > ^cursor_id)
            )
        end

      rows = query |> project() |> Repo.all()
      shifts = Enum.take(rows, options.limit)
      has_more = length(rows) > options.limit

      cursor =
        if has_more do
          last = List.last(shifts)

          Base.url_encode64(Jason.encode!([1, DateTime.to_iso8601(last.starts_at), last.id]),
            padding: false
          )
        end

      {:ok, %{shifts: shifts, has_more: has_more, next_cursor: cursor}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp project(query), do: select(query, [w], map(w, ^@fields))

  defp list_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:from, :until, :limit, :cursor])) do
      with limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 50),
           {:ok, first} <- optional_instant(Keyword.get(opts, :from)),
           {:ok, last} <- optional_instant(Keyword.get(opts, :until)),
           true <- is_nil(first) or is_nil(last) or DateTime.compare(first, last) == :lt,
           {:ok, cursor} <- cursor(Keyword.get(opts, :cursor)) do
        {:ok, %{limit: limit, from: first, until: last, cursor: cursor}}
      else
        _ -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp list_options(_), do: {:error, :invalid_options}
  defp optional_instant(nil), do: {:ok, nil}
  defp optional_instant(value), do: WorkShift.instant(value)
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
