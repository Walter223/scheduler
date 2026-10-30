defmodule SchedulerApi.Employment.Offboarding do
  @moduledoc "Atomic HR offboarding; never grants scheduling or general role-management authority."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership}

  alias SchedulerApi.Employment.{
    EmploymentRecord,
    ShopAssignment,
    WorkShift,
    WorkShiftAuditEvent,
    HrAuditEvent,
    OffboardingAudit
  }

  alias SchedulerApi.Appointments.{Appointment, JobAssignment, JobAssignmentAuditEvent}

  def terminate(credential, employment) do
    case Repo.transaction(fn ->
           e = reference(employment) || Repo.rollback(:forbidden)

           b =
             RoleManagement.lock_business(%Business{id: e.business_id}) ||
               Repo.rollback(:forbidden)

           # Before any employment/child lock, match RoleManagement's sorted eligibility
           # locks. Nested audited revocation must never upgrade parents after children.
           if not preauthorized?(credential, b), do: Repo.rollback(:forbidden)
           RoleManagement.lock_business_members(b.id)
           actor = actor(credential) || Repo.rollback(:forbidden)

           if Authorization.authorize(actor.user, :employment_manage, b) != :ok,
             do: Repo.rollback(:forbidden)

           e = Repo.one!(from p in EmploymentRecord, where: p.id == ^e.id, lock: "FOR UPDATE")

           if e.status == :ended do
             unless Repo.exists?(from a in OffboardingAudit, where: a.employment_id == ^e.id),
               do: Repo.rollback(:legacy_termination_requires_review)

             %{employment: project(e), already_terminated: true}
           else
             now = DateTime.utc_now() |> DateTime.truncate(:second)

             today =
               now
               |> SchedulerApi.Appointments.Availability.local_datetime()
               |> NaiveDateTime.to_date()

             assignments =
               Repo.all(
                 from a in ShopAssignment,
                   where: a.employment_id == ^e.id,
                   order_by: a.id,
                   lock: "FOR UPDATE"
               )

             if Date.compare(e.starts_on, today) == :gt or
                  Enum.any?(assignments, fn a ->
                    Date.compare(a.ends_on || a.starts_on, today) == :gt
                  end),
                do: Repo.rollback(:future_assignment_dates)

             shop_ids = Enum.map(assignments, & &1.shop_id)
             Repo.all(from s in Shop, where: s.id in ^shop_ids, order_by: s.id, lock: "FOR SHARE")

             shifts =
               Repo.all(
                 from w in WorkShift,
                   where: w.employment_id == ^e.id and w.status == :active,
                   order_by: w.id,
                   lock: "FOR UPDATE"
               )

             appointments =
               from j in JobAssignment,
                 where: j.employment_id == ^e.id and j.status == :active,
                 select: j.appointment_id

             Repo.all(
               from a in Appointment,
                 where: a.id in subquery(appointments),
                 order_by: a.id,
                 lock: "FOR UPDATE"
             )

             jobs =
               Repo.all(
                 from j in JobAssignment,
                   where: j.employment_id == ^e.id and j.status == :active,
                   order_by: [asc: j.appointment_id, asc: j.id],
                   lock: "FOR UPDATE"
               )

             if Enum.any?(shifts ++ jobs, fn w ->
                  DateTime.compare(w.starts_at, now) == :lt and
                    DateTime.compare(w.ends_at, now) == :gt
                end),
                do: Repo.rollback(:work_in_progress)

             future_jobs = Enum.filter(jobs, &(DateTime.compare(&1.starts_at, now) != :lt))
             future_shifts = Enum.filter(shifts, &(DateTime.compare(&1.starts_at, now) != :lt))
             # All mutations below are private to this HR transaction and exact target.
             # No fake scheduler credential or role elevation is used for Business Managers.
             for j <- future_jobs do
               old_lead =
                 Repo.one(
                   from p in JobAssignment,
                     where:
                       p.appointment_id == ^j.appointment_id and p.status == :active and p.is_lead,
                     select: p.id
                 )

               save!(
                 Repo.update(
                   Ecto.Changeset.change(j, status: :unassigned, is_lead: false, closed_at: now),
                   log: false
                 )
               )

               save!(
                 Repo.insert(
                   %JobAssignmentAuditEvent{
                     actor_user_id: actor.user_id,
                     business_id: j.business_id,
                     shop_id: j.shop_id,
                     appointment_id: j.appointment_id,
                     job_id: j.id,
                     previous_lead_job_id: old_lead,
                     lead_job_id: if(old_lead == j.id, do: nil, else: old_lead),
                     action: :remove_member,
                     outcome: :applied,
                     reason: "unassigned",
                     occurred_at: now
                   },
                   log: false
                 )
               )
             end

             for w <- future_shifts do
               save!(Repo.update(WorkShift.close_changeset(w, :cancelled, now), log: false))

               save!(
                 Repo.insert(
                   %WorkShiftAuditEvent{
                     actor_user_id: actor.user_id,
                     business_id: w.business_id,
                     shop_id: w.shop_id,
                     employment_id: e.id,
                     assignment_id: w.assignment_id,
                     shift_id: w.id,
                     action: :cancel,
                     outcome: :applied,
                     reason: :cancelled,
                     occurred_at: now
                   },
                   log: false
                 )
               )
             end

             for a <- assignments, a.status == :active do
               save!(Repo.update(ShopAssignment.end_changeset(a, today), log: false))

               save!(
                 Repo.insert(
                   %HrAuditEvent{
                     actor_user_id: actor.user_id,
                     business_id: e.business_id,
                     employment_id: e.id,
                     assignment_id: a.id,
                     shop_id: a.shop_id,
                     action: :end_shop,
                     outcome: :applied,
                     reason: "ended",
                     changed_fields: ["ends_on"],
                     occurred_at: now
                   },
                   log: false
                 )
               )
             end

             membership =
               if e.user_id,
                 do: Repo.get_by!(BusinessMembership, user_id: e.user_id, business_id: b.id)

             if membership do
               # Nested transactions share the outer transaction, NOT savepoints. Every
               # error explicitly aborts the entire offboarding, including prior audits.
               case RoleManagement.revoke_employment_access(credential, e) do
                 {:ok, _} -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end

             ended = save!(Repo.update(EmploymentRecord.end_changeset(e, today), log: false))

             save!(
               Repo.insert(
                 %OffboardingAudit{
                   actor_user_id: actor.user_id,
                   business_id: b.id,
                   employment_id: e.id,
                   membership_id: membership && membership.id,
                   ended_on: today,
                   jobs_removed: length(future_jobs),
                   shifts_cancelled: length(future_shifts),
                   assignments_ended: Enum.count(assignments, &(&1.status == :active)),
                   occurred_at: now
                 },
                 log: false
               )
             )

             %{employment: project(ended), already_terminated: false}
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
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

  defp reference(%EmploymentRecord{id: id}) when is_integer(id),
    do: Repo.get(EmploymentRecord, id)

  defp reference(_), do: nil

  defp preauthorized?(%SessionCredential{} = credential, business) do
    case Accounts.get_session_by_token(SessionCredential.reveal(credential)) do
      {:ok, session} -> Authorization.authorize(session.user, :employment_manage, business) == :ok
      _ -> false
    end
  end

  defp preauthorized?(_, _), do: false

  defp actor(%SessionCredential{} = credential) do
    token = SessionCredential.reveal(credential)

    with {:ok, s} <- Accounts.get_session_by_token(token) do
      Repo.one(
        from u in SchedulerApi.Accounts.User, where: u.id == ^s.user_id, lock: "FOR UPDATE"
      )

      Repo.one(from w in WebSession, where: w.id == ^s.id, lock: "FOR UPDATE")

      case Accounts.get_session_by_token(token) do
        {:ok, current} -> current
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp actor(_), do: nil
  defp save!({:ok, v}), do: v
  defp save!({:error, _}), do: Repo.rollback(:persistence_failed)

  defp project(e),
    do:
      Map.take(e, [
        :id,
        :business_id,
        :first_name,
        :last_name,
        :classification,
        :status,
        :starts_on,
        :ends_on
      ])
end
