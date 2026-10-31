defmodule SchedulerApi.Employment.Directory do
  @moduledoc "Session-backed HR REST read projections; stable employee IDs are not period IDs."
  import Ecto.Query
  alias SchedulerApi.{Repo, Authorization}
  alias SchedulerApi.Accounts.{WebSession, User}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment}

  @fields [
    :employee_id,
    :business_id,
    :first_name,
    :last_name,
    :classification,
    :status,
    :starts_on,
    :ends_on,
    :phone,
    :email,
    :home_address
  ]
  @timeline [
    :employee_id,
    :business_id,
    :first_name,
    :last_name,
    :classification,
    :status,
    :starts_on,
    :ends_on
  ]

  def read(session, kind, business_id, resource_id, period_id, params) do
    with {:ok, user, sessions} <- session_scope(session),
         {:ok, biz} <- id(business_id),
         {:ok, resource} <- optional_id(resource_id),
         {:ok, period} <- optional_id(period_id) do
      action =
        if kind == :shop, do: :assigned_employee_contact_read, else: :employment_private_read

      allowed = Authorization.employment_scopes_query(user, action)

      scopes =
        from p in subquery(allowed),
          join: s in subquery(sessions),
          on: true,
          where: p.business_id == ^biz

      scopes =
        if kind == :shop,
          do: where(scopes, [p], p.shop_id == ^resource),
          else: where(scopes, [p], is_nil(p.shop_id))

      if Repo.exists?(scopes) do
        base =
          from e in EmploymentRecord,
            join: p in subquery(scopes),
            on: p.business_id == e.business_id

        query = build(base, kind, resource, period)

        cond do
          kind in [:profile, :period] ->
            with :ok <- params_allowed(params, []),
                 value when not is_nil(value) <- Repo.one(project(query, kind)) do
              {:ok, %{employee: value}}
            else
              nil -> {:error, :forbidden}
              error -> error
            end

          kind == :history and not Repo.exists?(query) ->
            {:error, :forbidden}

          true ->
            paginate(query, kind, biz, resource, params)
        end
      else
        {:error, :forbidden}
      end
    end
  end

  defp build(base, :shop, shop, _) do
    from [e, p] in base,
      join: a in ShopAssignment,
      on: a.employment_id == e.id and a.business_id == e.business_id and a.shop_id == p.shop_id,
      where:
        a.shop_id == ^shop and a.status == :active and e.status == :active and
          a.starts_on <= fragment("(CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date") and
          e.starts_on <= fragment("(CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date"),
      distinct: true
  end

  defp build(base, :history, employee, _),
    do: from(e in base, where: e.employee_id == ^employee, distinct: true)

  defp build(base, :period, employee, period),
    do: from(e in base, where: e.employee_id == ^employee and e.id == ^period, distinct: true)

  defp build(base, kind, employee, _) when kind in [:directory, :profile] do
    latest =
      from e in base,
        distinct: e.employee_id,
        order_by: [asc: e.employee_id, desc: e.starts_on, desc: e.id],
        select: %{id: e.id}

    query =
      from [e, p] in base, join: latest in subquery(latest), on: latest.id == e.id, distinct: true

    if kind == :profile, do: where(query, [e], e.employee_id == ^employee), else: query
  end

  defp paginate(query, kind, biz, resource, params) do
    allowed =
      if kind == :directory,
        do: ["limit", "cursor", "status", "q", "classification"],
        else:
          if(kind == :shop,
            do: ["limit", "cursor", "q", "classification"],
            else: ["limit", "cursor"]
          )

    with :ok <- params_allowed(params, allowed),
         {:ok, limit} <- limit(Map.get(params, "limit", "50")),
         {:ok, status} <- status(kind, Map.get(params, "status", "active")),
         {:ok, search, classification} <- filters(params),
         binding =
           if(search == "" and is_nil(classification),
             do: status,
             else: Jason.encode!([status, search, classification])
           ),
         {:ok, position} <-
           cursor(Map.get(params, "cursor"), [Atom.to_string(kind), biz, resource || 0, binding]) do
      query =
        case status do
          "active" ->
            where(
              query,
              [e],
              e.status == :active and
                e.starts_on <= fragment("(CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date")
            )

          "former" ->
            where(query, [e], e.status == :ended)

          _ ->
            query
        end

      query =
        if search == "",
          do: query,
          else:
            where(
              query,
              [e],
              fragment(
                "strpos(lower(? || ' ' || ?), lower(?)) > 0",
                e.first_name,
                e.last_name,
                ^search
              )
            )

      query =
        if is_nil(classification),
          do: query,
          else: where(query, [e], e.classification == ^classification)

      key = if kind == :history, do: :id, else: :employee_id

      query =
        from e in query,
          where: field(e, ^key) > ^position,
          order_by: field(e, ^key),
          limit: ^(limit + 1)

      rows = Repo.all(project(query, kind, if(kind == :shop, do: resource)))
      items = Enum.take(rows, limit)
      more = length(rows) > limit

      next =
        if more do
          value =
            Map.fetch!(List.last(items), if(kind == :history, do: :period_id, else: :employee_id))

          Base.url_encode64(
            Jason.encode!([1, Atom.to_string(kind), biz, resource || 0, binding, value]),
            padding: false
          )
        end

      {:ok,
       %{employees: items, meta: %{has_more: more, next_cursor: next, timezone: "America/Denver"}}}
    end
  end

  defp project(query, kind, shop \\ nil) do
    fields = if kind == :history, do: @timeline, else: @fields
    query = from e in query, select: map(e, ^fields), select_merge: %{period_id: e.id}

    if kind == :history,
      do: query,
      else:
        from(e in query,
          select_merge: %{
            shops:
              fragment(
                "(SELECT coalesce(jsonb_agg(jsonb_build_object('assignment_id',a.id,'id',s.id,'name',s.name,'status',a.status,'starts_on',a.starts_on,'ends_on',a.ends_on) ORDER BY s.id,a.id),'[]') FROM employment_shop_assignments a JOIN shops s ON s.id=a.shop_id AND s.business_id=a.business_id WHERE a.employment_id=? AND s.status='active' AND (?::bigint IS NULL OR (s.id=?::bigint AND a.status='active' AND a.starts_on <= (CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date)))",
                e.id,
                ^shop,
                ^shop
              )
          }
        )
  end

  defp filters(params) do
    q = Map.get(params, "q", "")
    c = Map.get(params, "classification")

    roles = %{
      "detailer" => :detailer,
      "shop_manager" => :shop_manager,
      "business_manager" => :business_manager,
      "business_owner" => :business_owner
    }

    if is_binary(q) and byte_size(q) <= 100 and String.valid?(q) and
         (is_nil(c) or Map.has_key?(roles, c)),
       do: {:ok, String.trim(q), roles[c]},
       else: {:error, :invalid_options}
  end

  defp session_scope(%WebSession{id: id, user_id: user_id})
       when is_integer(id) and is_integer(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from s in WebSession,
        join: u in User,
        on: u.id == s.user_id,
        where:
          s.id == ^id and s.user_id == ^user_id and is_nil(s.revoked_at) and
            s.idle_expires_at > ^now and s.absolute_expires_at > ^now and u.status == :active and
            u.email_verified,
        select: %{id: s.id}

    if Repo.exists?(query), do: {:ok, %User{id: user_id}, query}, else: {:error, :unauthenticated}
  end

  defp session_scope(_), do: {:error, :unauthenticated}

  defp params_allowed(params, allowed) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 in allowed)), do: :ok, else: {:error, :invalid_options}
  end

  defp params_allowed(_, _), do: {:error, :invalid_options}

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> {:error, :invalid_options}
    end
  end

  defp id(_), do: {:error, :invalid_options}
  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(v), do: id(v)

  defp limit(v) do
    case id(v) do
      {:ok, n} when n <= 100 -> {:ok, n}
      _ -> {:error, :invalid_options}
    end
  end

  defp status(:directory, v) when v in ["active", "former", "all"], do: {:ok, v}
  defp status(:directory, _), do: {:error, :invalid_options}
  defp status(_, _), do: {:ok, "scoped"}
  defp cursor(nil, _), do: {:ok, 0}

  defp cursor(v, [kind, biz, resource, status]) when is_binary(v) and byte_size(v) <= 512 do
    with {:ok, json} <- Base.url_decode64(v, padding: false),
         {:ok, [1, ^kind, ^biz, ^resource, ^status, n]} <- Jason.decode(json),
         true <- is_integer(n) and n > 0 and n <= 9_223_372_036_854_775_807 do
      {:ok, n}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp cursor(_, _), do: {:error, :invalid_options}
end
