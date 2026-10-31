defmodule SchedulerApi.Authorization.RoleManagement do
  @moduledoc "Audited internal customer role operations. Requires an opaque actor credential, never a claimed user ID."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{User, SessionCredential, WebSession}

  alias SchedulerApi.Organizations.{
    Business,
    Shop,
    BusinessMembership,
    RoleAssignment,
    Memberships
  }

  alias SchedulerApi.Authorization.AuditEvent

  def grant_role(actor, business, membership, role, shop \\ nil),
    do: run(:grant_role, actor, business, membership, role, shop)

  def revoke_role(actor, business, assignment),
    do: run(:revoke_role, actor, business, assignment, nil, nil)

  def revoke_membership(actor, business, membership),
    do: run(:revoke_membership, actor, business, membership, nil, nil)

  def reactivate_membership(actor, business, membership),
    do: run(:reactivate_membership, actor, business, membership, nil, nil)

  @doc "HR-only revocation tied to a persisted active employment, never arbitrary membership scope."
  def revoke_employment_access(credential, %SchedulerApi.Employment.EmploymentRecord{id: id})
      when is_integer(id) do
    e = Repo.get(SchedulerApi.Employment.EmploymentRecord, id)

    if e && e.user_id do
      m = Repo.get_by(BusinessMembership, user_id: e.user_id, business_id: e.business_id)
      run(:revoke_membership, credential, %Business{id: e.business_id}, m, nil, nil, e.id)
    else
      {:error, :invalid_target}
    end
  end

  def revoke_employment_access(_, _), do: {:error, :invalid_target}

  defp run(action, credential, business_ref, target_ref, role, shop_ref, employment_id \\ nil) do
    result =
      Repo.transaction(fn ->
        business = lock_business(business_ref)
        if business, do: lock_business_members(business.id)
        actor = actor(credential)
        {membership, assignment} = load_target(target_ref, business, action)
        shop = load_shop(shop_ref, business)

        metadata = %{
          actor_user_id: actor && actor.user.id,
          business_id: business && business.id,
          target_user_id: membership && membership.user_id,
          membership_id: membership && membership.id,
          role_assignment_id: assignment && assignment.id,
          role:
            if(assignment,
              do: assignment.role,
              else: if(role in RoleAssignment.roles(), do: role)
            ),
          shop_id: if(assignment, do: assignment.shop_id, else: shop && shop.id)
        }

        cascade =
          if membership && action == :revoke_membership do
            Repo.all(
              from r in RoleAssignment,
                where: r.membership_id == ^membership.id and r.status == :active
            )
          else
            []
          end

        outcome =
          cond do
            is_nil(business) or is_nil(actor) or
                not authorized_change?(
                  actor.user,
                  business,
                  membership,
                  employment_id,
                  action,
                  if(assignment, do: assignment.role, else: role)
                ) ->
              {:error, :forbidden}

            is_nil(membership) ->
              {:error, :invalid_target}

            action == :grant_role ->
              grant(membership, role, shop, shop_ref)

            action == :revoke_role ->
              revoke(assignment, membership, actor.user.id)

            action == :revoke_membership ->
              revoke_membership_locked(membership, actor.user.id)

            action == :reactivate_membership ->
              reactivate(membership)
          end

        {kind, reason, value} =
          case outcome do
            {:ok, value} -> {:applied, :changed, value}
            {:noop, reason, value} -> {:noop, reason, value}
            {:error, reason} -> {:denied, reason, nil}
          end

        metadata =
          if action == :grant_role and value,
            do: %{metadata | role_assignment_id: value.id},
            else: metadata

        # Expected denials COMMIT only an event. Audit failure rolls back mutations
        # too. No separate connection/transaction can claim a rolled-back success.
        case Repo.insert(
               struct!(
                 AuditEvent,
                 Map.merge(metadata, %{
                   action: action,
                   outcome: kind,
                   reason: reason,
                   occurred_at: now()
                 })
               ),
               log: false
             ) do
          {:ok, _} ->
            if kind == :applied and action == :revoke_membership do
              Enum.each(cascade, fn r ->
                fields =
                  Map.merge(metadata, %{
                    action: :revoke_role,
                    role_assignment_id: r.id,
                    role: r.role,
                    shop_id: r.shop_id,
                    outcome: :applied,
                    reason: :changed,
                    occurred_at: now()
                  })

                Repo.insert!(struct!(AuditEvent, fields), log: false)
              end)
            end

            if kind == :denied, do: {:error, reason}, else: {:ok, value}

          {:error, _} ->
            Repo.rollback(:persistence_failed)
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _} -> {:error, :persistence_failed}
    end
  rescue
    # Do not propagate SQL arguments, opaque credentials or raw exception terms.
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :persistence_failed}
  end

  defp authorized_change?(user, business, membership, nil, action, role),
    do: Authorization.authorize_role_change(user, business, membership, action, role) == :ok

  defp authorized_change?(user, business, membership, employment_id, _, _) do
    e = Repo.get(SchedulerApi.Employment.EmploymentRecord, employment_id)

    valid =
      e && membership && e.status == :active && e.business_id == business.id &&
        e.user_id == membership.user_id

    if valid && Authorization.authorize(user, :employment_terminate, e) == :ok do
      owner =
        Repo.exists?(
          from r in RoleAssignment,
            where:
              r.membership_id == ^membership.id and r.status == :active and
                r.role == :business_owner
        )

      # Last-owner enforcement still occurs in revoke_membership_locked/2.
      not owner or last_owner?(membership) or
        Authorization.authorize(user, :access_manage, business) == :ok
    else
      false
    end
  end

  # Shared lock namespace for every customer access mutation, including operator bootstrap.
  @doc false
  def lock_business(%Business{id: id}) when is_integer(id) and id > 0,
    do: Repo.one(from b in Business, where: b.id == ^id, lock: "FOR UPDATE")

  def lock_business(_), do: nil

  @doc false
  def lock_business_members(business_id) do
    # One business row serializes cooperating role changes. Lock eligibility rows
    # in stable order before session/membership/grant rows (Accounts locks user first).
    ids = from m in BusinessMembership, where: m.business_id == ^business_id, select: m.user_id
    Repo.all(from u in User, where: u.id in subquery(ids), order_by: u.id, lock: "FOR UPDATE")

    Repo.all(
      from m in BusinessMembership,
        where: m.business_id == ^business_id,
        order_by: m.id,
        lock: "FOR UPDATE"
    )

    Repo.all(
      from r in RoleAssignment,
        where: r.business_id == ^business_id,
        order_by: r.id,
        lock: "FOR UPDATE"
    )
  end

  defp actor(%SessionCredential{} = credential) do
    token = SessionCredential.reveal(credential)

    with {:ok, session} <- Accounts.get_session_by_token(token) do
      # Lock session after its user; serialize against logout/rotation, then recheck.
      Repo.one(from s in WebSession, where: s.id == ^session.id, lock: "FOR UPDATE")

      case Accounts.get_session_by_token(token) do
        {:ok, current} -> current
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp actor(_), do: nil

  defp load_target(%BusinessMembership{} = ref, %Business{} = business, action)
       when action != :revoke_role and is_integer(ref.id) and ref.id > 0 do
    m = Repo.get(BusinessMembership, ref.id)

    if m && m.business_id == business.id && ref.business_id == m.business_id &&
         ref.user_id == m.user_id, do: {m, nil}, else: {nil, nil}
  end

  defp load_target(%RoleAssignment{} = ref, %Business{} = business, :revoke_role)
       when is_integer(ref.id) and ref.id > 0 do
    r = Repo.get(RoleAssignment, ref.id)

    if r && r.business_id == business.id && ref.business_id == r.business_id &&
         ref.membership_id == r.membership_id && ref.role == r.role && ref.shop_id == r.shop_id do
      {Repo.get!(BusinessMembership, r.membership_id), r}
    else
      {nil, nil}
    end
  end

  defp load_target(_, _, _), do: {nil, nil}

  defp load_shop(%Shop{id: id, business_id: b}, %Business{id: b}) when is_integer(id) and id > 0,
    do:
      Repo.one(
        from s in Shop,
          where: s.id == ^id and s.business_id == ^b and s.status == :active,
          lock: "FOR SHARE"
      )

  defp load_shop(_, _), do: nil

  defp grant(m, role, shop, shop_ref) do
    cond do
      role not in RoleAssignment.roles() ->
        {:error, :invalid_role}

      role in [:business_owner, :business_manager] and not is_nil(shop_ref) ->
        {:error, :invalid_scope}

      role in [:shop_manager, :employee] and is_nil(shop) ->
        {:error, :invalid_scope}

      m.status != :active or not eligible?(Repo.get!(User, m.user_id)) or
          not Authorization.access_target_employment_eligible?(m) ->
        {:error, :ineligible_target}

      true ->
        attrs = %RoleAssignment{
          membership_id: m.id,
          business_id: m.business_id,
          shop_id: shop && shop.id
        }

        query =
          from r in RoleAssignment,
            where: r.membership_id == ^m.id and r.role == ^role and r.status == :active

        query =
          if shop,
            do: where(query, [r], r.shop_id == ^shop.id),
            else: where(query, [r], is_nil(r.shop_id))

        existing = Repo.one(query)

        if existing do
          {:error, :duplicate_grant}
        else
          case attrs |> RoleAssignment.creation_changeset(%{role: role}) |> Repo.insert() do
            {:ok, r} -> {:ok, r}
            {:error, _} -> Repo.rollback(:persistence_failed)
          end
        end
    end
  end

  defp revoke(r, m, actor_id) do
    cond do
      r.status == :revoked ->
        {:noop, :already_revoked, r}

      r.role == :business_owner and last_owner?(m) ->
        {:error, :last_owner}

      true ->
        {:ok,
         Repo.update!(
           Ecto.Changeset.change(r,
             status: :revoked,
             revoked_at: now(),
             revoked_by_user_id: actor_id,
             revocation_reason: :manual
           )
         )}
    end
  end

  defp revoke_membership_locked(m, actor_id) do
    cond do
      m.status == :revoked -> {:noop, :already_revoked, m}
      last_owner?(m) -> {:error, :last_owner}
      true -> Memberships.revoke(m, actor_id: actor_id)
    end
  end

  defp reactivate(m) do
    cond do
      not eligible?(Repo.get!(User, m.user_id)) -> {:error, :ineligible_target}
      m.status == :active -> {:noop, :already_active, m}
      true -> Memberships.reactivate(m)
    end
  end

  defp last_owner?(m) do
    owners =
      Repo.all(
        from r in RoleAssignment,
          join: member in BusinessMembership,
          on: member.id == r.membership_id,
          join: u in User,
          on: u.id == member.user_id,
          where:
            r.business_id == ^m.business_id and r.role == :business_owner and r.status == :active and
              member.status == :active and u.status == :active and u.email_verified == true,
          select: member.id
      )

    m.id in owners and length(owners) == 1
  end

  defp eligible?(u), do: u.status == :active and u.email_verified
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
