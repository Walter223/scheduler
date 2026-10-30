defmodule SchedulerApi.Authorization.OwnerBootstrap do
  @moduledoc """
  Explicit deployment-operator command boundary, never an HTTP/account activation
  operation. Shell/deployment and database access control who can invoke it;
  audit source identifies invocation context, not a verified human identity.
  """
  import Ecto.Query
  alias SchedulerApi.{Repo, Authorization}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Authorization.{AuditEvent, RoleManagement}

  def run(business_id, issuer, subject, opts \\ []) do
    with :ok <- options(opts) do
      result =
        Repo.transaction(fn ->
          business =
            if is_integer(business_id) and business_id > 0,
              do: RoleManagement.lock_business(%Business{id: business_id})

          user = lookup_identity(issuer, subject)

          membership =
            if business && user,
              do:
                Repo.one(
                  from m in BusinessMembership,
                    where: m.business_id == ^business.id and m.user_id == ^user.id,
                    lock: "FOR UPDATE"
                )

          reason =
            cond do
              is_nil(business) ->
                :invalid_business

              business.status != :active ->
                :inactive_business

              is_nil(user) ->
                :invalid_identity

              user.status != :active or not user.email_verified ->
                :ineligible_target

              Repo.exists?(
                from r in RoleAssignment,
                  where: r.business_id == ^business.id and r.role == :business_owner
              ) ->
                :existing_owner_history

              membership && membership.status != :active ->
                :inactive_membership

              true ->
                nil
            end

          apply? = Keyword.get(opts, :apply, false)

          cond do
            reason ->
              if apply?, do: audit!(business, user, membership, nil, :denied, reason)
              {:error, reason}

            not apply? ->
              {:ok,
               %{
                 mode: :dry_run,
                 business_id: business.id,
                 user_id: user.id,
                 role: :business_owner,
                 membership: if(membership, do: :reuse, else: :create)
               }}

            true ->
              membership =
                membership ||
                  Repo.insert!(
                    BusinessMembership.creation_changeset(%BusinessMembership{
                      user_id: user.id,
                      business_id: business.id
                    })
                  )

              assignment =
                Repo.insert!(
                  RoleAssignment.creation_changeset(
                    %RoleAssignment{membership_id: membership.id, business_id: business.id},
                    %{role: :business_owner}
                  )
                )

              # Assert the same complete-grant policy used by normal authorization.
              if Authorization.authorize(user, :access_manage, business) != :ok,
                do: Repo.rollback(:persistence_failed)

              audit!(business, user, membership, assignment, :applied, :changed)

              {:ok,
               %{
                 mode: :applied,
                 business_id: business.id,
                 user_id: user.id,
                 membership_id: membership.id,
                 role_assignment_id: assignment.id
               }}
          end
        end)

      case result do
        {:ok, outcome} -> outcome
        {:error, _} -> {:error, :persistence_failed}
      end
    end
  rescue
    # Never print exceptions/SQL arguments or raw identity/provider data.
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :persistence_failed}
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(opts, fn {k, v} -> k == :apply and is_boolean(v) end) and
         length(opts) <= 1, do: :ok, else: {:error, :invalid_options}
  end

  defp options(_), do: {:error, :invalid_options}

  defp lookup_identity(issuer, subject)
       when is_binary(issuer) and is_binary(subject) and
              byte_size(issuer) in 1..1024 and byte_size(subject) in 1..1024 do
    # Exact case-sensitive immutable identity pair; no email lookup/normalization.
    Repo.one(
      from u in User,
        where: u.keycloak_issuer == ^issuer and u.keycloak_subject == ^subject,
        lock: "FOR UPDATE"
    )
  end

  defp lookup_identity(_, _), do: nil

  defp audit!(business, user, membership, assignment, outcome, reason) do
    Repo.insert!(
      %AuditEvent{
        source: :deployment_operator_command,
        action: :bootstrap_owner,
        actor_user_id: nil,
        target_user_id: user && user.id,
        business_id: business && business.id,
        membership_id: membership && membership.id,
        role_assignment_id: assignment && assignment.id,
        role: :business_owner,
        shop_id: nil,
        outcome: outcome,
        reason: reason,
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      log: false
    )
  end
end
