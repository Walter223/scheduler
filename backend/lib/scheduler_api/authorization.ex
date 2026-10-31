defmodule SchedulerApi.Authorization do
  @moduledoc """
  Current persisted grants only; no session or platform bypass. Callers must
  authenticate separately. Each decision requires one complete assignment.
  Resource structs are references only: ownership/status is reloaded from DB.
  """
  import Ecto.Query
  alias SchedulerApi.Repo
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Appointments.{Appointment, JobAssignment}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment, WorkShift}

  @business_actions [
    :business_manage,
    :access_manage,
    :staff_access_read,
    :staff_access_manage,
    :employment_manage,
    :employment_private_read,
    :compensation_read,
    :compensation_write,
    :payroll_manage,
    :finance_manage
  ]
  @shop_actions [
    :appointments_read,
    :appointments_manage,
    :schedule_manage,
    :jobs_assign,
    :customers_manage,
    :shop_operations_manage,
    :shop_staff_manage
  ]
  # Contact and own-employment reads now resolve actual employment records.
  # Pay, shifts and assigned jobs have separate persisted-record guards below.
  @assigned_staff [:assigned_employee_contact_read, :assigned_employee_compensation_read]
  @own_work [
    :jobs_assigned_read,
    :schedule_own_read,
    :employment_own_read,
    :compensation_own_read
  ]
  @hr_record_actions [:employment_terminate, :employment_rehire]
  @manager_permissions [
    :employment_manage,
    :employment_terminate,
    :employment_rehire,
    :employment_private_read,
    :compensation_read,
    :compensation_write,
    :payroll_manage,
    :finance_manage,
    :staff_access_read,
    :staff_access_manage
  ]
  @permissions %{
    business_owner:
      Enum.uniq(
        @manager_permissions ++
          @business_actions ++
          @shop_actions ++
          @assigned_staff ++ @own_work ++ @hr_record_actions
      ),
    business_manager: @manager_permissions,
    shop_manager: @shop_actions ++ @assigned_staff,
    employee: @own_work
  }

  @doc "Fixed policy names, not proof of effective access. Unknown roles return []."
  def permissions(role), do: Map.get(@permissions, role, [])

  @doc "Returns :ok or {:error, :forbidden}; unknown/unverifiable targets fail closed."
  def authorize(%User{id: id}, action, %Business{id: business_id})
      when is_integer(id) and id > 0 and is_integer(business_id) and action in @business_actions do
    grants(id, action)
    |> where([r, m, u, b], b.id == ^business_id and is_nil(r.shop_id))
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %Shop{id: shop_id}) when is_integer(shop_id) do
    from(s in subquery(authorized_shop_ids_query(user, action)), where: s.id == ^shop_id)
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %Appointment{id: id})
      when is_integer(id) and action in [:appointments_read, :appointments_manage] do
    # Never authorize caller-supplied business/shop fields or a generic ownership map.
    from(a in Appointment,
      join: s in subquery(authorized_shop_ids_query(user, action)),
      on: s.id == a.shop_id,
      join: shop in Shop,
      on: shop.id == a.shop_id and shop.business_id == a.business_id,
      where: a.id == ^id
    )
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{id: user_id}, action, %EmploymentRecord{id: id})
      when is_integer(user_id) and user_id > 0 and is_integer(id) and action in @hr_record_actions do
    protected = management_employments([:business_owner])
    # One current grant supplies both HR authority and business scope. Current
    # or historical ownership is a restriction, never a source of permission.
    from([r, m, u, b] in grants(user_id, action),
      join: e in EmploymentRecord,
      on: e.business_id == b.id,
      where:
        e.id == ^id and is_nil(r.shop_id) and
          (r.role == :business_owner or e.id not in subquery(protected))
    )
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %EmploymentRecord{id: id})
      when is_integer(id) and
             action in [
               :employment_private_read,
               :assigned_employee_contact_read,
               :employment_own_read
             ] do
    from(e in subquery(authorized_employment_ids_query(user, action)), where: e.id == ^id)
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %EmploymentRecord{id: id})
      when is_integer(id) and
             action in [
               :compensation_read,
               :compensation_write,
               :assigned_employee_compensation_read,
               :compensation_own_read
             ] do
    from(e in subquery(authorized_compensation_employment_ids_query(user, action)),
      where: e.id == ^id
    )
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %WorkShift{id: id})
      when is_integer(id) and action in [:schedule_manage, :schedule_own_read] do
    from(w in subquery(authorized_work_shift_ids_query(user, action)), where: w.id == ^id)
    |> Repo.exists?()
    |> decision()
  end

  def authorize(%User{} = user, action, %JobAssignment{id: id})
      when is_integer(id) and action in [:jobs_assign, :jobs_assigned_read] do
    from(j in subquery(authorized_job_assignment_ids_query(user, action)), where: j.id == ^id)
    |> Repo.exists?()
    |> decision()
  end

  def authorize(_, _, _), do: {:error, :forbidden}

  @doc """
  Composable query selecting %{id: shop_id} for a shop-level action. Use as a
  subquery BEFORE pagination. The query re-evaluates DB state when executed;
  materialized IDs/results must not be cached as authorization credentials.
  Unknown/deferred actions return an empty query.
  """
  def authorized_shop_ids_query(%User{id: id}, action)
      when is_integer(id) and id > 0 and action in @shop_actions do
    from [r, m, u, b] in grants(id, action),
      join: s in Shop,
      on: s.business_id == b.id,
      where: s.status == :active and (is_nil(r.shop_id) or r.shop_id == s.id),
      distinct: true,
      select: %{id: s.id}
  end

  def authorized_shop_ids_query(_, _), do: from(s in Shop, where: false, select: %{id: s.id})

  @employment_reads [
    :employment_private_read,
    :assigned_employee_contact_read,
    :employment_own_read,
    :compensation_own_read
  ]

  @doc """
  Complete persisted grants for employment collections. Each row retains its own
  business/shop/user scope; callers must never flatten these into separate sets.
  Contact scopes require an active shop; business HR scopes do not require staff.
  """
  def employment_scopes_query(%User{id: id}, action)
      when is_integer(id) and id > 0 and action in @employment_reads do
    query = grants(id, action)

    case action do
      :employment_private_read ->
        from [r, m, u, b] in query,
          where: is_nil(r.shop_id),
          select: %{business_id: b.id, shop_id: r.shop_id, user_id: u.id},
          distinct: true

      :assigned_employee_contact_read ->
        from [r, m, u, b] in query,
          join: s in Shop,
          on: s.business_id == b.id,
          where: s.status == :active and (is_nil(r.shop_id) or r.shop_id == s.id),
          select: %{business_id: b.id, shop_id: s.id, user_id: u.id},
          distinct: true

      own when own in [:employment_own_read, :compensation_own_read] ->
        from [r, m, u, b] in query,
          left_join: s in Shop,
          on: s.id == r.shop_id and s.business_id == b.id and s.status == :active,
          where: is_nil(r.shop_id) or not is_nil(s.id),
          select: %{business_id: b.id, shop_id: r.shop_id, user_id: u.id},
          distinct: true
    end
  end

  def employment_scopes_query(_, _),
    do:
      from(m in BusinessMembership,
        where: false,
        select: %{
          business_id: m.business_id,
          shop_id: fragment("NULL::bigint"),
          user_id: m.user_id
        }
      )

  @doc """
  SQL-authorized current employment IDs WITH their supporting shop scope.
  Dates use the existing Magnum America/Denver calendar. :now is a trusted clock,
  never a caller-selected authorization date. Target account state does not erase
  employment from HR/contact rosters; self-service requires current actor eligibility.
  """
  def authorized_employment_ids_query(user, action, now \\ DateTime.utc_now())

  def authorized_employment_ids_query(user, action, %DateTime{} = now)
      when action in @employment_reads do
    scopes = employment_scopes_query(user, action)
    now = now |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)

    query =
      from e in EmploymentRecord,
        join: p in subquery(scopes),
        on: p.business_id == e.business_id,
        left_join: a in ShopAssignment,
        on:
          a.employment_id == e.id and a.business_id == e.business_id and a.shop_id == p.shop_id and
            a.status == :active and
            a.starts_on <= fragment("(?::timestamptz AT TIME ZONE 'America/Denver')::date", ^now),
        where:
          e.status == :active and
            e.starts_on <= fragment("(?::timestamptz AT TIME ZONE 'America/Denver')::date", ^now) and
            (is_nil(p.shop_id) or not is_nil(a.id)),
        distinct: true,
        select: %{id: e.id, business_id: e.business_id, shop_id: p.shop_id}

    if action in [:employment_own_read, :compensation_own_read],
      do: where(query, [e, p], e.user_id == p.user_id),
      else: query
  end

  def authorized_employment_ids_query(_, _, _),
    do:
      from(e in EmploymentRecord,
        where: false,
        select: %{id: e.id, business_id: e.business_id, shop_id: fragment("NULL::bigint")}
      )

  @doc """
  Record-specific compensation authority, never inferred from classification.
  HR history access includes ended employment. Owner pay is restricted even if a
  linked Owner was misclassified; management-role history is scoped to this business.
  Shop reads require an active/current Detailer and an assigned active shop.
  """
  def authorized_compensation_employment_ids_query(user, action, now \\ DateTime.utc_now())

  def authorized_compensation_employment_ids_query(
        %User{id: id} = user,
        action,
        %DateTime{} = now
      )
      when is_integer(id) and id > 0 and
             action in [
               :compensation_read,
               :compensation_write,
               :assigned_employee_compensation_read,
               :compensation_own_read
             ] do
    case action do
      :compensation_own_read ->
        from e in subquery(authorized_employment_ids_query(user, action, now)),
          distinct: true,
          select: %{id: e.id}

      hr when hr in [:compensation_read, :compensation_write] ->
        owners = management_employments([:business_owner])

        from [r, m, u, b] in grants(id, hr),
          join: e in EmploymentRecord,
          on: e.business_id == b.id,
          where:
            is_nil(r.shop_id) and
              (r.role == :business_owner or
                 (e.classification != :business_owner and e.id not in subquery(owners))),
          distinct: true,
          select: %{id: e.id}

      :assigned_employee_compensation_read ->
        management = management_employments([:business_owner, :business_manager, :shop_manager])
        now = now |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)

        from [r, m, u, b] in grants(id, action),
          join: s in Shop,
          on: s.business_id == b.id,
          join: a in ShopAssignment,
          on: a.shop_id == s.id and a.business_id == b.id,
          join: e in EmploymentRecord,
          on: e.id == a.employment_id and e.business_id == b.id,
          where:
            s.status == :active and (is_nil(r.shop_id) or r.shop_id == s.id) and
              a.status == :active and e.status == :active and e.classification == :detailer and
              a.starts_on <=
                fragment("(?::timestamptz AT TIME ZONE 'America/Denver')::date", ^now) and
              e.starts_on <=
                fragment("(?::timestamptz AT TIME ZONE 'America/Denver')::date", ^now) and
              e.id not in subquery(management),
          distinct: true,
          select: %{id: e.id}
    end
  end

  def authorized_compensation_employment_ids_query(_, _, _),
    do: from(e in EmploymentRecord, where: false, select: %{id: e.id})

  @doc "Complete business-scoped access grants and permitted target memberships, for SQL scoping."
  def staff_access_scopes_query(user, business_id, action \\ :staff_access_read)

  def staff_access_scopes_query(%User{id: id}, business_id, action)
      when is_integer(id) and id > 0 and action in [:staff_access_read, :staff_access_manage] do
    protected_employment = management_employments([:business_owner])

    protected_users =
      from e in EmploymentRecord,
        where: e.business_id == ^business_id and e.id in subquery(protected_employment),
        select: e.user_id

    owner_memberships =
      from r in RoleAssignment,
        where: r.business_id == ^business_id and r.role == :business_owner,
        select: r.membership_id

    from [r, m, u, b] in grants(id, action),
      join: target in BusinessMembership,
      on: target.business_id == b.id,
      join: person in User,
      on: person.id == target.user_id,
      where: b.id == ^business_id and is_nil(r.shop_id),
      where:
        r.role == :business_owner or
          (target.user_id != u.id and target.status == :active and is_nil(target.revoked_at) and
             person.status == :active and person.email_verified and
             target.id not in subquery(owner_memberships) and
             target.user_id not in subquery(
               from p in subquery(protected_users), where: not is_nil(p.user_id)
             )),
      distinct: true,
      select: %{membership_id: target.id, owner: r.role == :business_owner}
  end

  def staff_access_scopes_query(_, _, _),
    do: from(m in BusinessMembership, where: false, select: %{membership_id: m.id, owner: false})

  @doc "Transaction callers must lock business/eligibility rows first; selectors supply no authority."
  def authorize_role_change(%User{} = user, %Business{} = business, membership, action, role)
      when action in [:grant_role, :revoke_role, :revoke_membership, :reactivate_membership] do
    cond do
      authorize(user, :access_manage, business) == :ok ->
        :ok

      action not in [:grant_role, :revoke_role] or role not in [:employee, :shop_manager] ->
        {:error, :forbidden}

      not match?(%BusinessMembership{}, membership) ->
        {:error, :forbidden}

      true ->
        from(s in subquery(staff_access_scopes_query(user, business.id, :staff_access_manage)),
          where: s.membership_id == ^membership.id
        )
        |> Repo.exists?()
        |> decision()
    end
  end

  def authorize_role_change(_, _, _, _, _), do: {:error, :forbidden}

  @doc false
  def access_target_employment_eligible?(membership) do
    periods =
      from e in EmploymentRecord,
        where: e.user_id == ^membership.user_id and e.business_id == ^membership.business_id

    # An explicitly created new period may start in the future. Fresh grants may
    # be prepared, but period-specific reads still enforce their effective dates.
    # A terminated-only identity cannot regain access by reactivating membership.
    not Repo.exists?(periods) or Repo.exists?(from e in periods, where: e.status == :active)
  end

  defp management_employments(roles) do
    # Both revoked management grants AND any past management classification stay
    # sensitive. A later Employee grant/reclassification never downgrades pay privacy.
    role_history =
      from e in EmploymentRecord,
        join: m in BusinessMembership,
        on: m.user_id == e.user_id and m.business_id == e.business_id,
        join: r in RoleAssignment,
        on: r.membership_id == m.id and r.business_id == e.business_id,
        where: r.role in ^roles,
        select: e.id

    classifications =
      from h in SchedulerApi.Employment.ClassificationHistory,
        join: old in EmploymentRecord,
        on: old.id == h.employment_id and old.business_id == h.business_id,
        join: current in EmploymentRecord,
        on: current.employee_id == old.employee_id and current.business_id == old.business_id,
        where: h.classification in ^roles or h.previous_classification in ^roles,
        select: current.id

    from e in EmploymentRecord,
      where:
        e.classification in ^roles or e.id in subquery(role_history) or
          e.id in subquery(classifications),
      select: e.id
  end

  @doc "Complete current grant scopes for management or linked own-shift reads."
  def work_shift_scopes_query(%User{id: id}, action)
      when is_integer(id) and id > 0 and action in [:schedule_manage, :schedule_own_read] do
    scopes =
      from [r, m, u, b] in grants(id, action),
        join: s in Shop,
        on: s.business_id == b.id,
        where: s.status == :active and (is_nil(r.shop_id) or r.shop_id == s.id)

    if action == :schedule_manage do
      from [r, m, u, b, s] in scopes,
        distinct: true,
        select: %{business_id: b.id, shop_id: s.id, assignment_id: fragment("NULL::bigint")}
    else
      from [r, m, u, b, s] in scopes,
        join: e in EmploymentRecord,
        on: e.business_id == b.id and e.user_id == u.id,
        join: a in ShopAssignment,
        on: a.employment_id == e.id and a.business_id == b.id and a.shop_id == s.id,
        where: e.status == :active and a.status == :active,
        distinct: true,
        select: %{business_id: b.id, shop_id: s.id, assignment_id: a.id}
    end
  end

  def work_shift_scopes_query(_, _),
    do:
      from(s in Shop,
        where: false,
        select: %{
          business_id: s.business_id,
          shop_id: s.id,
          assignment_id: fragment("NULL::bigint")
        }
      )

  @doc "SQL shift scope; full assignment identity stays joined to its qualifying role grant."
  def authorized_work_shift_ids_query(user, action) do
    scopes = work_shift_scopes_query(user, action)

    from w in WorkShift,
      join: p in subquery(scopes),
      on:
        w.business_id == p.business_id and w.shop_id == p.shop_id and
          (is_nil(p.assignment_id) or w.assignment_id == p.assignment_id),
      distinct: true,
      select: %{id: w.id, business_id: w.business_id, shop_id: w.shop_id}
  end

  @doc "Complete current assignment scopes for job management or linked Detailer own work."
  def job_scopes_query(%User{id: id}, action)
      when is_integer(id) and id > 0 and action in [:jobs_assign, :jobs_assigned_read] do
    scopes =
      from [r, m, u, b] in grants(id, action),
        join: s in Shop,
        on: s.business_id == b.id,
        where: s.status == :active and (is_nil(r.shop_id) or r.shop_id == s.id)

    if action == :jobs_assign do
      from [r, m, u, b, s] in scopes,
        distinct: true,
        select: %{business_id: b.id, shop_id: s.id, assignment_id: fragment("NULL::bigint")}
    else
      from [r, m, u, b, s] in scopes,
        join: e in EmploymentRecord,
        on: e.business_id == b.id and e.user_id == u.id,
        join: a in ShopAssignment,
        on: a.employment_id == e.id and a.business_id == b.id and a.shop_id == s.id,
        where:
          e.status == :active and e.classification == :detailer and a.status == :active and
            e.starts_on <= fragment("(CURRENT_TIMESTAMP AT TIME ZONE ?)::date", s.timezone) and
            a.starts_on <= fragment("(CURRENT_TIMESTAMP AT TIME ZONE ?)::date", s.timezone),
        distinct: true,
        select: %{business_id: b.id, shop_id: s.id, assignment_id: a.id}
    end
  end

  def job_scopes_query(_, _),
    do:
      from(s in Shop,
        where: false,
        select: %{
          business_id: s.business_id,
          shop_id: s.id,
          assignment_id: fragment("NULL::bigint")
        }
      )

  @doc "Job SQL scope is applied before projection and pagination; no role/scope mixing."
  def authorized_job_assignment_ids_query(user, action) do
    query =
      from j in JobAssignment,
        join: p in subquery(job_scopes_query(user, action)),
        on:
          j.business_id == p.business_id and j.shop_id == p.shop_id and
            (is_nil(p.assignment_id) or j.assignment_id == p.assignment_id),
        join: a in Appointment,
        on:
          a.id == j.appointment_id and a.business_id == j.business_id and a.shop_id == j.shop_id,
        distinct: true,
        select: %{id: j.id}

    if action == :jobs_assigned_read,
      do: where(query, [j, p, a], j.status == :active and a.status in [:pending, :confirmed]),
      else: query
  end

  @doc "One complete operational grant per shop; All Shops requires business-wide scope."
  def dashboard_shops_query(%User{id: id}, business_id, shop_id) do
    roles =
      for {role, actions} <- @permissions,
          Enum.all?([:appointments_read, :schedule_manage, :jobs_assign], &(&1 in actions)),
          do: role

    query =
      from [r, m, u, b] in grants(id, :appointments_read),
        join: s in Shop,
        on: s.business_id == b.id,
        where: b.id == ^business_id and s.status == :active and r.role in ^roles,
        distinct: true,
        select: %{id: s.id, name: s.name, timezone: s.timezone}

    if is_nil(shop_id),
      do: where(query, [r], is_nil(r.shop_id)),
      else:
        where(
          query,
          [r, m, u, b, s],
          s.id == ^shop_id and (is_nil(r.shop_id) or r.shop_id == s.id)
        )
  end

  @doc "Minimal current management contexts; no role labels or employee self-service elevation."
  def admin_contexts(%User{id: id} = user) do
    areas = [
      dashboard: :employment_private_read,
      employees: :employment_private_read,
      roster: :assigned_employee_contact_read,
      compensation: :compensation_read,
      access: :staff_access_read,
      settings: :business_manage,
      appointments: :appointments_read,
      schedules: :schedule_manage
    ]

    # Candidate discovery is still restricted by live complete grants, including
    # shop-only operational grants. Candidates never authorize a capability.
    candidates =
      from r in RoleAssignment,
        join: m in BusinessMembership,
        on: m.id == r.membership_id and m.business_id == r.business_id,
        join: u in User,
        on: u.id == m.user_id,
        join: b in Business,
        on: b.id == m.business_id,
        where:
          u.id == ^id and u.status == :active and u.email_verified and
            m.status == :active and is_nil(m.revoked_at) and r.status == :active and
            is_nil(r.revoked_at) and b.status == :active,
        distinct: true,
        order_by: b.id,
        select: b

    for b <- Repo.all(candidates), reduce: [] do
      result ->
        capabilities =
          for {area, action} <- areas,
              Repo.exists?(
                from [r, m, u, business] in grants(id, action),
                  where: business.id == ^b.id and is_nil(r.shop_id)
              ),
              do: area

        shops =
          for shop <-
                Repo.all(
                  from s in Shop,
                    where: s.business_id == ^b.id and s.status == :active,
                    order_by: s.id
                ),
              reduce: [] do
            shops ->
              allowed =
                for {area, action} <- areas,
                    action in (@shop_actions ++ @assigned_staff),
                    discovery_shop_allowed?(user, action, shop),
                    do: area

              if allowed == [],
                do: shops,
                else: shops ++ [%{id: shop.id, name: shop.name, capabilities: allowed}]
          end

        if capabilities == [] and shops == [],
          do: result,
          else:
            result ++
              [
                %{
                  id: b.id,
                  name: b.name,
                  capabilities:
                    Enum.uniq(
                      capabilities ++
                        if(shops != [], do: [:dashboard], else: [])
                    ),
                  all_shops: Enum.filter(capabilities, &(&1 in [:appointments, :schedules])),
                  shops: shops
                }
              ]
    end
  end

  defp discovery_shop_allowed?(user, :assigned_employee_contact_read, shop) do
    from(p in subquery(employment_scopes_query(user, :assigned_employee_contact_read)),
      where: p.business_id == ^shop.business_id and p.shop_id == ^shop.id
    )
    |> Repo.exists?()
  end

  defp discovery_shop_allowed?(user, action, shop), do: authorize(user, action, shop) == :ok

  defp grants(user_id, action) do
    roles = for {role, actions} <- @permissions, action in actions, do: role

    from r in RoleAssignment,
      join: m in BusinessMembership,
      on: m.id == r.membership_id and m.business_id == r.business_id,
      join: u in User,
      on: u.id == m.user_id,
      join: b in Business,
      on: b.id == m.business_id,
      where:
        u.id == ^user_id and u.status == :active and u.email_verified == true and
          m.status == :active and is_nil(m.revoked_at) and
          r.status == :active and is_nil(r.revoked_at) and r.role in ^roles and
          b.status == :active
  end

  defp decision(true), do: :ok
  defp decision(false), do: {:error, :forbidden}
end
