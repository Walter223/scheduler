defmodule SchedulerApi.Employment.Rehire do
  @moduledoc "Explicit, audited creation of an empty employment period; never restores access or work."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.Business
  alias SchedulerApi.Employment.{EmploymentRecord, OffboardingAudit, RehireAudit}

  def rehire(credential, ref, starts_on) do
    case Repo.transaction(fn ->
           e = reference(ref) || Repo.rollback(:forbidden)

           b =
             RoleManagement.lock_business(%Business{id: e.business_id}) ||
               Repo.rollback(:forbidden)

           if not eligible?(credential, b), do: Repo.rollback(:forbidden)
           RoleManagement.lock_business_members(b.id)
           actor = actor(credential) || Repo.rollback(:forbidden)

           if Authorization.authorize(actor.user, :employment_manage, b) != :ok,
             do: Repo.rollback(:forbidden)

           root =
             Repo.one!(
               from e in EmploymentRecord, where: e.id == ^e.employee_id, lock: "FOR UPDATE"
             )

           e = Repo.one!(from p in EmploymentRecord, where: p.id == ^e.id, lock: "FOR UPDATE")

           if Authorization.authorize(actor.user, :employment_rehire, e) != :ok,
             do: Repo.rollback(:forbidden)

           latest =
             Repo.one!(
               from p in EmploymentRecord,
                 where: p.employee_id == ^root.id,
                 order_by: [desc: p.starts_on, desc: p.id],
                 limit: 1
             )

           if e.id != latest.id or e.status != :ended, do: Repo.rollback(:not_latest_ended_period)

           unless Repo.exists?(from a in OffboardingAudit, where: a.employment_id == ^e.id),
             do: Repo.rollback(:offboarding_required)

           date = date(starts_on)

           if is_nil(date) or Date.compare(date, e.ends_on) != :gt,
             do: Repo.rollback(:invalid_start_date)

           now = DateTime.utc_now() |> DateTime.truncate(:second)
           # Copy only stable identity/name and classification, never private contact,
           # memberships, pay or work. Explicit HR contact edits can populate the new period.
           new = %EmploymentRecord{
             employee_id: root.id,
             business_id: b.id,
             user_id: root.user_id,
             first_name: e.first_name,
             last_name: e.last_name,
             classification: e.classification,
             starts_on: date,
             inserted_at: now,
             updated_at: now
           }

           new = save!(Repo.insert(new, log: false))

           save!(
             Repo.insert(
               %RehireAudit{
                 actor_user_id: actor.user_id,
                 business_id: b.id,
                 employee_id: root.id,
                 previous_period_id: e.id,
                 period_id: new.id,
                 occurred_at: now
               },
               log: false
             )
           )

           project(new)
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

  def history(user, %EmploymentRecord{id: id}) when is_integer(id) do
    e = Repo.get(EmploymentRecord, id)
    scopes = Authorization.employment_scopes_query(user, :employment_private_read)

    if e do
      allowed =
        from p in subquery(scopes), where: p.business_id == ^e.business_id and is_nil(p.shop_id)

      if Repo.exists?(allowed) do
        {:ok,
         Repo.all(
           from p in EmploymentRecord,
             join: a in subquery(allowed),
             on: p.business_id == a.business_id,
             where: p.employee_id == ^e.employee_id,
             order_by: [asc: p.starts_on, asc: p.id],
             select:
               map(p, [
                 :id,
                 :employee_id,
                 :business_id,
                 :first_name,
                 :last_name,
                 :classification,
                 :status,
                 :starts_on,
                 :ends_on
               ])
         )}
      else
        {:error, :forbidden}
      end
    else
      {:error, :forbidden}
    end
  end

  def history(_, _), do: {:error, :forbidden}

  defp reference(%EmploymentRecord{id: id}) when is_integer(id),
    do: Repo.get(EmploymentRecord, id)

  defp reference(_), do: nil

  defp eligible?(%SessionCredential{} = credential, b) do
    case Accounts.get_session_by_token(SessionCredential.reveal(credential)) do
      {:ok, s} -> Authorization.authorize(s.user, :employment_manage, b) == :ok
      _ -> false
    end
  end

  defp eligible?(_, _), do: false

  defp actor(%SessionCredential{} = credential) do
    token = SessionCredential.reveal(credential)

    with {:ok, s} <- Accounts.get_session_by_token(token) do
      Repo.one(from w in WebSession, where: w.id == ^s.id, lock: "FOR UPDATE")

      case Accounts.get_session_by_token(token) do
        {:ok, current} -> current
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp date(%Date{} = v), do: v

  defp date(v) when is_binary(v) and byte_size(v) == 10 do
    case Date.from_iso8601(v) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp save!({:ok, v}), do: v
  defp save!({:error, _}), do: Repo.rollback(:persistence_failed)

  defp project(e),
    do:
      Map.take(e, [
        :id,
        :employee_id,
        :business_id,
        :first_name,
        :last_name,
        :classification,
        :status,
        :starts_on,
        :ends_on
      ])
end
