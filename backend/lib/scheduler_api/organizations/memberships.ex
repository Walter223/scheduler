defmodule SchedulerApi.Organizations.Memberships do
  @moduledoc "Internal persistence lifecycle only. No authorization, activation or role-management API."
  import Ecto.Query
  alias SchedulerApi.Repo
  alias SchedulerApi.Organizations.BusinessMembership

  @doc false
  def revoke(%BusinessMembership{id: id}, opts \\ []) do
    transition(id, :revoked, opts)
  end

  @doc false
  def reactivate(%BusinessMembership{id: id}, opts \\ []) do
    transition(id, :active, opts)
  end

  defp transition(id, status, opts) do
    with {:ok, now} <- SchedulerApi.Authentication.now(opts) do
      Repo.transaction(fn ->
        membership =
          Repo.one(from m in BusinessMembership, where: m.id == ^id, lock: "FOR UPDATE") ||
            Repo.rollback(:membership_not_found)

        if membership.status == status do
          membership
        else
          changes =
            if status == :revoked,
              do: [
                status: status,
                revoked_at: now,
                revoked_by_user_id: Keyword.get(opts, :actor_id),
                revocation_reason: :manual,
                updated_at: now
              ],
              else: [
                status: status,
                revoked_at: nil,
                revoked_by_user_id: nil,
                revocation_reason: nil,
                updated_at: now
              ]

          case membership
               |> Ecto.Changeset.change(changes)
               |> Ecto.Changeset.check_constraint(:status, name: :business_memberships_lifecycle)
               |> Ecto.Changeset.foreign_key_constraint(:revoked_by_user_id)
               |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end)
    end
  end
end
