defmodule SchedulerApi.Employment do
  @moduledoc """
  Employment persistence and authorized read projections. Mutations remain trusted
  internal persistence primitives, NOT authorized HR/account-linking APIs.
  Read callers must authenticate actors separately; current persisted RBAC scopes
  govern all projections. No account, grant or scheduling effects.
  """
  import Ecto.Query
  alias SchedulerApi.{Repo, Authorization}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment}

  @doc "Business-wide current roster/contact projection for Business Owners/Managers."
  def list_business_roster(user, business, opts \\ [])

  def list_business_roster(%User{} = user, %Business{id: id}, opts)
      when is_integer(id) and id > 0,
      do: roster(user, :employment_private_read, {:business, id}, opts)

  def list_business_roster(_, _, _), do: {:error, :forbidden}

  @doc "Current staff/contact projection at one authorized shop; no other shop memberships are exposed."
  def list_shop_roster(user, shop, opts \\ [])

  def list_shop_roster(%User{} = user, %Shop{id: id}, opts) when is_integer(id) and id > 0,
    do: roster(user, :assigned_employee_contact_read, {:shop, id}, opts)

  def list_shop_roster(_, _, _), do: {:error, :forbidden}

  @doc "Only the caller's current linked employment, backed by a complete own-read grant."
  def get_own_employment(user, business, opts \\ [])

  def get_own_employment(%User{} = user, %Business{id: id}, opts)
      when is_integer(id) and id > 0 do
    action = :employment_own_read
    scope = {:business, id}

    with true <- Repo.exists?(read_scopes(user, action, scope)),
         :ok <- read_options(opts, [:now]),
         {:ok, now} <- read_clock(opts) do
      case Repo.one(projected_records(user, action, scope, now)) do
        nil -> {:error, :forbidden}
        record -> {:ok, record}
      end
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def get_own_employment(_, _, _), do: {:error, :forbidden}

  defp roster(user, action, scope, opts) do
    with true <- Repo.exists?(read_scopes(user, action, scope)),
         :ok <- read_options(opts, [:now, :limit, :cursor]),
         {:ok, now} <- read_clock(opts),
         {:ok, limit} <- roster_limit(Keyword.get(opts, :limit, 50)),
         {:ok, cursor} <- roster_cursor(Keyword.get(opts, :cursor)) do
      rows =
        projected_records(user, action, scope, now)
        |> where([e], e.id > ^cursor)
        |> order_by([e], asc: e.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      records = Enum.take(rows, limit)
      has_more = length(rows) > limit

      next_cursor =
        if has_more,
          do: Base.url_encode64(Jason.encode!([1, List.last(records).id]), padding: false)

      {:ok, %{employments: records, has_more: has_more, next_cursor: next_cursor}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp read_scopes(user, action, scope),
    do: user |> Authorization.employment_scopes_query(action) |> filter_scope(scope)

  defp filter_scope(query, {:business, id}),
    do: from(p in subquery(query), where: p.business_id == ^id)

  defp filter_scope(query, {:shop, id}), do: from(p in subquery(query), where: p.shop_id == ^id)

  defp projected_records(user, action, scope, now) do
    allowed =
      user |> Authorization.authorized_employment_ids_query(action, now) |> filter_scope(scope)

    # The supporting scope stays with its grant through the target-assignment
    # join. DISTINCT collapses overlapping grants before LIMIT or cursor creation.
    from e in EmploymentRecord,
      join: p in subquery(allowed),
      on: e.id == p.id and e.business_id == p.business_id,
      distinct: true,
      select: %{
        id: e.id,
        business_id: e.business_id,
        first_name: e.first_name,
        last_name: e.last_name,
        classification: e.classification,
        starts_on: e.starts_on,
        phone: e.phone,
        email: e.email,
        home_address: e.home_address
      }
  end

  defp read_options(opts, allowed) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp read_clock(opts) do
    case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
      %DateTime{} = now -> {:ok, now |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)}
      _ -> {:error, :invalid_clock}
    end
  end

  defp roster_limit(limit) when is_integer(limit) and limit in 1..100, do: {:ok, limit}
  defp roster_limit(_), do: {:error, :invalid_limit}
  defp roster_cursor(nil), do: {:ok, 0}

  defp roster_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, id]} <- Jason.decode(json),
         true <- is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 do
      {:ok, id}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp roster_cursor(_), do: {:error, :invalid_cursor}

  @doc "Creates independent employment; optional :user must already be eligible in this business."
  def create_employment(%Business{id: id}, attrs, opts \\ []) do
    Repo.transaction(fn ->
      business = active_business!(id)

      user_id =
        case Keyword.get(opts, :user) do
          nil -> nil
          %User{id: user_id} when is_integer(user_id) -> user_id
          _ -> Repo.rollback(:invalid_user)
        end

      %EmploymentRecord{business_id: business.id, user_id: user_id}
      |> EmploymentRecord.creation_changeset(attrs)
      |> insert!()
    end)
  end

  @doc "Tenant-scoped internal retrieval; not an authorization decision."
  def get_employment(%Business{id: business_id}, id) do
    Repo.one(from e in EmploymentRecord, where: e.id == ^id and e.business_id == ^business_id)
  end

  def list_employments(%Business{id: business_id}) do
    Repo.all(from e in EmploymentRecord, where: e.business_id == ^business_id, order_by: e.id)
  end

  def assign_shop(%EmploymentRecord{id: id}, %Shop{id: shop_id}, attrs) do
    Repo.transaction(fn ->
      # Compensation/role writes lock business first. Match that order before
      # locking employment so assignment creation cannot form a lock cycle.
      reference =
        Repo.one(
          from e in EmploymentRecord, where: e.id == ^id, select: %{business_id: e.business_id}
        ) || Repo.rollback(:employment_not_found)

      active_business!(reference.business_id)
      employment = lock_employment!(id)
      if employment.status != :active, do: Repo.rollback(:employment_ended)
      shop = Repo.one(from s in Shop, where: s.id == ^shop_id, lock: "FOR SHARE")

      cond do
        is_nil(shop) -> Repo.rollback(:shop_not_found)
        shop.business_id != employment.business_id -> Repo.rollback(:wrong_business)
        shop.status != :active -> Repo.rollback(:inactive_shop)
        true -> :ok
      end

      %ShopAssignment{
        employment_id: employment.id,
        business_id: employment.business_id,
        shop_id: shop.id
      }
      |> ShopAssignment.creation_changeset(attrs)
      |> insert!()
    end)
  end

  def list_shop_assignments(%Business{id: business_id}, %EmploymentRecord{id: id}) do
    Repo.all(
      from a in ShopAssignment,
        where: a.business_id == ^business_id and a.employment_id == ^id,
        order_by: a.id
    )
  end

  @doc "Ends all active shop assignments and employment atomically; ended history is terminal."
  def end_employment(%EmploymentRecord{id: id}, %Date{} = date) do
    Repo.transaction(fn ->
      employment = lock_employment!(id)

      if employment.status == :ended do
        if employment.ends_on != date, do: Repo.rollback(:already_ended)
        employment
      else
        assignments =
          Repo.all(from a in ShopAssignment, where: a.employment_id == ^id, order_by: a.id)

        if Date.compare(date, employment.starts_on) == :lt or
             Enum.any?(assignments, fn a ->
               Date.compare(date, a.ends_on || a.starts_on) == :lt
             end),
           do: Repo.rollback(:invalid_end_date)

        for a <- assignments, a.status == :active do
          a |> ShopAssignment.end_changeset(date) |> update!()
        end

        employment |> EmploymentRecord.end_changeset(date) |> update!()
      end
    end)
  end

  def end_employment(_, _), do: {:error, :invalid_date}

  def end_shop_assignment(%ShopAssignment{id: id}, %Date{} = date) do
    Repo.transaction(fn ->
      reference = Repo.get(ShopAssignment, id) || Repo.rollback(:assignment_not_found)
      # Always parent before child, matching assignment creation and termination.
      lock_employment!(reference.employment_id)
      assignment = Repo.get!(ShopAssignment, id)

      if assignment.status == :ended do
        if assignment.ends_on != date, do: Repo.rollback(:already_ended)
        assignment
      else
        if Date.compare(date, assignment.starts_on) == :lt, do: Repo.rollback(:invalid_end_date)
        assignment |> ShopAssignment.end_changeset(date) |> update!()
      end
    end)
  end

  def end_shop_assignment(_, _), do: {:error, :invalid_date}

  defp active_business!(id) do
    business =
      Repo.one(from b in Business, where: b.id == ^id, lock: "FOR SHARE") ||
        Repo.rollback(:business_not_found)

    if business.status != :active, do: Repo.rollback(:inactive_business)
    business
  end

  defp lock_employment!(id),
    do:
      Repo.one(from e in EmploymentRecord, where: e.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:employment_not_found)

  defp insert!(changeset), do: persist(Repo.insert(changeset))
  defp update!(changeset), do: persist(Repo.update(changeset))
  defp persist({:ok, value}), do: value
  defp persist({:error, changeset}), do: Repo.rollback(changeset)
end
