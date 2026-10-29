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
  alias SchedulerApi.Appointments.Appointment

  @business_actions [
    :business_manage,
    :access_manage,
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
  # Declared policy, but deliberately NOT executable until record ownership and
  # employment/job assignment relationships exist. No broad shop fallback.
  @assigned_staff [:assigned_employee_contact_read, :assigned_employee_compensation_read]
  @own_work [:jobs_assigned_read, :schedule_own_read, :employment_own_read]
  @permissions %{
    business_owner: @business_actions ++ @shop_actions ++ @assigned_staff ++ @own_work,
    business_manager: [
      :employment_manage,
      :employment_private_read,
      :compensation_read,
      :compensation_write,
      :payroll_manage,
      :finance_manage
    ],
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
