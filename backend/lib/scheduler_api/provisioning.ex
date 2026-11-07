defmodule SchedulerApi.Provisioning do
  @moduledoc """
  Create-new-business domain boundary. Only trusted deployment-operator code may
  call `authorize_operator/4`; it is not an HTTP authorization check. A persisted,
  random capability binds the exact eligible identity and validated request.
  `provision/2` accepts that capability, never an owner or existing-business selector.
  See BUSINESS_PROVISIONING.md before adding any new issuer of provisioning intents.
  """
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Authorization.AuditEvent
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Provisioning.{Credential, Intent}

  @doc "Trusted operator-only authorization of one exact create-new-business request."
  def authorize_operator(issuer, subject, attrs, opts \\ []) do
    with {:ok, clock} <- clock(opts),
         {:ok, business, shop} <- validate_request(attrs) do
      transaction(fn ->
        owner = lock_identity(issuer, subject)
        eligible!(owner)
        now = read_clock(clock)

        unless Repo.exists?(from z in "pg_timezone_names", where: z.name == ^shop.timezone),
          do: Repo.rollback(:invalid_input)

        credential = Credential.generate()
        {:ok, hash} = Credential.digest(credential)

        Repo.insert!(
          %Intent{
            owner_id: owner.id,
            credential_hash: hash,
            business_name: business.name,
            business_slug: business.slug,
            shop_name: shop.name,
            shop_slug: shop.slug,
            timezone: shop.timezone,
            expires_at: DateTime.add(now, 600),
            inserted_at: now,
            updated_at: now
          },
          log: false
        )

        credential
      end)
    end
  end

  @doc "Atomically provision, or return the original result without restoring any access."
  def provision(credential, opts \\ []) do
    with {:ok, clock} <- clock(opts),
         {:ok, hash} <- Credential.digest(credential) do
      transaction(fn ->
        intent =
          Repo.one(from(i in Intent, where: i.credential_hash == ^hash, lock: "FOR UPDATE"),
            log: false
          )

        if is_nil(intent), do: Repo.rollback(:invalid_intent)
        owner = Repo.one(from u in User, where: u.id == ^intent.owner_id, lock: "FOR UPDATE")
        eligible!(owner)
        now = read_clock(clock)

        cond do
          intent.completed_at ->
            result(intent)

          DateTime.compare(now, intent.expires_at) != :lt ->
            Repo.rollback(:expired_intent)

          true ->
            create!(intent, owner, now)
        end
      end)
    end
  end

  @doc false
  # Only Onboarding calls this under its proof/user locks. No operator issuer/capability.
  def create_from_onboarding!(%User{} = owner, attrs, now) do
    unless Repo.in_transaction?(), do: raise("Onboarding transaction required")

    with {:ok, business, shop} <- validate_request(attrs),
         true <- Repo.exists?(from z in "pg_timezone_names", where: z.name == ^shop.timezone) do
      activated = owner.status == :pending

      owner =
        if activated do
          case SchedulerApi.Accounts.set_user_status(owner, :active) do
            {:ok, user} -> user
            _ -> Repo.rollback(:ineligible_identity)
          end
        else
          owner
        end

      eligible!(owner)
      {:ok, hash} = Credential.digest(Credential.generate())

      intent =
        Repo.insert!(
          %Intent{
            owner_id: owner.id,
            credential_hash: hash,
            business_name: business.name,
            business_slug: business.slug,
            shop_name: shop.name,
            shop_slug: shop.slug,
            timezone: shop.timezone,
            source: :self_service_signup,
            activated_pending_account: activated,
            inserted_at: now,
            updated_at: now,
            expires_at: DateTime.add(now, 600)
          },
          log: false
        )

      create!(intent, owner, now)
    else
      _ -> Repo.rollback(:invalid_input)
    end
  end

  defp create!(intent, owner, now) do
    # The business is newly inserted and invisible to competing transactions.
    # No existing tenant is resolved, claimed, locked or modified here.
    business =
      case Repo.insert(
             Business.changeset(%Business{}, %{
               name: intent.business_name,
               slug: intent.business_slug,
               status: :active
             })
           ) do
        {:ok, b} -> b
        {:error, _} -> Repo.rollback(:slug_unavailable)
      end

    shop =
      Repo.insert!(
        Shop.changeset(%Shop{business_id: business.id}, %{
          name: intent.shop_name,
          slug: intent.shop_slug,
          timezone: intent.timezone,
          status: :active
        })
      )

    membership =
      Repo.insert!(
        BusinessMembership.creation_changeset(%BusinessMembership{
          user_id: owner.id,
          business_id: business.id
        })
      )

    grant =
      Repo.insert!(
        RoleAssignment.creation_changeset(
          %RoleAssignment{
            membership_id: membership.id,
            business_id: business.id
          },
          %{role: :business_owner}
        )
      )

    if Authorization.authorize(owner, :access_manage, business) != :ok,
      do: Repo.rollback(:persistence_failed)

    audit =
      Repo.insert!(
        %AuditEvent{
          source: intent.source,
          activated_pending_account: intent.activated_pending_account,
          actor_user_id: if(intent.source == :self_service_signup, do: owner.id),
          target_user_id: owner.id,
          business_id: business.id,
          shop_id: shop.id,
          membership_id: membership.id,
          role_assignment_id: grant.id,
          role: :business_owner,
          action: :provision_business,
          outcome: :applied,
          reason: :changed,
          occurred_at: now
        },
        log: false
      )

    intent
    |> Ecto.Changeset.change(
      business_id: business.id,
      shop_id: shop.id,
      membership_id: membership.id,
      role_assignment_id: grant.id,
      audit_event_id: audit.id,
      completed_at: now,
      updated_at: now
    )
    |> Repo.update!(log: false)
    |> result()
  end

  defp result(intent),
    do:
      Map.take(intent, [
        :business_id,
        :shop_id,
        :membership_id,
        :role_assignment_id,
        :audit_event_id
      ])

  defp validate_request(%{business: business, shop: shop} = attrs)
       when map_size(attrs) == 2 and is_map(business) and is_map(shop) do
    # Exact allowlists: no owner/business IDs, roles, statuses, catalog or settings.
    if Enum.sort(Map.keys(business)) == [:name, :slug] and
         Enum.sort(Map.keys(shop)) == [:name, :slug, :timezone] and
         Enum.all?(Map.values(business) ++ Map.values(shop), &is_binary/1) do
      b = Business.changeset(%Business{}, business)
      s = Shop.configuration_changeset(%Shop{}, shop)

      if b.valid? and s.valid? do
        {:ok, Ecto.Changeset.apply_changes(b), Ecto.Changeset.apply_changes(s)}
      else
        {:error, :invalid_input}
      end
    else
      {:error, :invalid_input}
    end
  end

  defp validate_request(_), do: {:error, :invalid_input}

  defp lock_identity(issuer, subject)
       when is_binary(issuer) and byte_size(issuer) in 1..1024 and
              is_binary(subject) and byte_size(subject) in 1..1024 do
    Repo.one(
      from u in User,
        where: u.keycloak_issuer == ^issuer and u.keycloak_subject == ^subject,
        lock: "FOR UPDATE"
    )
  end

  defp lock_identity(_, _), do: nil

  defp eligible!(%User{status: :active, email_verified: true}), do: :ok
  defp eligible!(_), do: Repo.rollback(:ineligible_identity)

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and
         Enum.all?(opts, fn {k, _} -> k == :now end) do
      case Keyword.fetch(opts, :now) do
        :error ->
          {:ok, :system}

        {:ok, %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = now} ->
          {:ok, DateTime.truncate(now, :second)}

        _ ->
          {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp clock(_), do: {:error, :invalid_options}

  # Read the production clock after row-lock waits, not before entering the transaction.
  defp read_clock(:system), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp read_clock(now), do: now

  defp transaction(fun) do
    Repo.transaction(fun)
  rescue
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :persistence_failed}
  end
end
