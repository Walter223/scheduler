defmodule SchedulerApi.BusinessOnboarding do
  @moduledoc "Private, revisioned Owner setup proposals; never applies tenant configuration."
  import Ecto.Query
  alias SchedulerApi.{Repo, Accounts, Authorization}
  alias SchedulerApi.Accounts.{SessionCredential, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.BusinessOnboarding.{Draft, Validation}

  @states ~w(provisioning_complete locations employees services_pricing branding review ready_to_publish completed)
  def states, do: @states
  def start(credential, id), do: run(credential, id, :start, nil)
  def get(credential, id), do: run(credential, id, :get, nil)
  def update(credential, id, attrs), do: run(credential, id, :update, attrs)

  def guide(credential, id, attrs \\ nil), do: run(credential, id, :guide, attrs)

  defp run(credential, id, action, attrs) do
    Repo.transaction(fn ->
      business = if is_integer(id), do: RoleManagement.lock_business(%Business{id: id})
      if business, do: RoleManagement.lock_business_members(business.id)
      session = actor!(credential)

      if is_nil(business) or
           Authorization.authorize(session.user, :access_manage, business) != :ok,
         do: Repo.rollback(:forbidden)

      draft = Repo.get_by(Draft, business_id: business.id)

      result =
        case action do
          :guide -> guide!(draft || Repo.rollback(:not_started), session.user.id, attrs)
          :start -> draft || begin!(business, session.user.id)
          :get -> draft || Repo.rollback(:not_started)
          :update -> change!(draft || Repo.rollback(:not_started), session.user.id, attrs)
        end

      if action == :guide do
        result
      else
        snapshot = if is_struct(result, Draft), do: projection(result), else: result

        snapshot =
          Map.put(
            snapshot,
            "effective_locations",
            Validation.effective_locations(snapshot["proposal"])
          )

        Map.put(snapshot, "applied", %{
          "business_id" => business.id,
          "shops" => shops(business.id)
        })
      end
    end)
  rescue
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :operation_unavailable}
  end

  @topics %{
    "locations" => ~w(locations defaults),
    "staff" => ~w(employees),
    "services" => ~w(services catalog),
    "branding" => ~w(branding)
  }
  defp guide_state(d, actor) do
    entry = d.guide_state[Integer.to_string(actor)] || %{}

    if (entry["expires_at"] || 0) > System.system_time(:second),
      do: entry,
      else: %{"history" => []}
  end

  defp guide_projection(d, actor),
    do: Map.merge(guide_state(d, actor), %{"revision" => d.revision, "engine_version" => 1})

  defp guide!(d, actor, nil), do: guide_projection(d, actor)

  defp guide!(d, actor, attrs) do
    unless is_map(attrs) and
             Enum.sort(Map.keys(attrs)) ==
               Enum.sort(~w(action topic proposal revision request_id)) and
             attrs["action"] in ~w(propose approve discard) and
             Map.has_key?(@topics, attrs["topic"]) and
             is_integer(attrs["revision"]),
           do: Repo.rollback(:invalid_input)

    uuid =
      case Ecto.UUID.cast(attrs["request_id"]) do
        {:ok, id} -> id
        _ -> Repo.rollback(:invalid_input)
      end

    hash = :crypto.hash(:sha256, :erlang.term_to_binary(attrs, [:deterministic]))

    receipt =
      Repo.one(
        from r in "business_onboarding_receipts",
          where:
            r.draft_id == ^d.id and r.actor_user_id == ^actor and
              r.request_id == type(^uuid, Ecto.UUID),
          select: r.request_hash
      )

    cond do
      receipt == hash ->
        guide_projection(d, actor)

      receipt != nil ->
        Repo.rollback(:request_conflict)

      attrs["revision"] != d.revision ->
        Repo.rollback(:revision_conflict)

      d.state == "completed" ->
        Repo.rollback(:invalid_transition)

      true ->
        entry = guide_state(d, actor)
        topic = attrs["topic"]
        action = attrs["action"]

        {entry, current} =
          case action do
            "propose" ->
              patch = attrs["proposal"]

              unless is_map(patch) and map_size(patch) > 0 and
                       Enum.all?(Map.keys(patch), &(&1 in @topics[topic])),
                     do: Repo.rollback(:invalid_input)

              p = Map.merge(d.proposal, patch)

              unless Validation.valid?(p, d.business_id) and
                       Map.drop(p, @topics[topic]) == Map.drop(d.proposal, @topics[topic]),
                     do: Repo.rollback(:invalid_input)

              {Map.put(entry, "pending", %{
                 "topic" => topic,
                 "proposal" => p,
                 "base_revision" => d.revision + 1
               }), d}

            "approve" ->
              pending = entry["pending"]

              unless attrs["proposal"] == nil and is_map(pending) and pending["topic"] == topic and
                       pending["base_revision"] == d.revision,
                     do: Repo.rollback(:revision_conflict)

              change!(d, actor, %{
                "revision" => d.revision,
                "request_id" => Ecto.UUID.generate(),
                "state" => d.state,
                "proposal" => pending["proposal"]
              })

              {Map.delete(entry, "pending"), Repo.get!(Draft, d.id)}

            "discard" ->
              unless attrs["proposal"] == nil, do: Repo.rollback(:invalid_input)
              {Map.delete(entry, "pending"), d}
          end

        history =
          Enum.take(
            (entry["history"] || []) ++
              [%{"action" => action, "topic" => topic, "revision" => d.revision + 1}],
            -20
          )

        entry =
          Map.merge(entry, %{
            "history" => history,
            "expires_at" => System.system_time(:second) + 604_800
          })

        current =
          Repo.update!(
            Ecto.Changeset.change(current,
              guide_state:
                Map.put(
                  Map.filter(current.guide_state, fn {_, v} ->
                    (v["expires_at"] || 0) > System.system_time(:second)
                  end),
                  Integer.to_string(actor),
                  entry
                ),
              revision: d.revision + 1
            ),
            log: false
          )

        if action != "approve", do: audit!(current, actor, d.state)

        Repo.insert_all(
          "business_onboarding_receipts",
          [
            %{
              draft_id: d.id,
              actor_user_id: actor,
              request_id: Ecto.UUID.dump!(uuid),
              request_hash: hash,
              result: %{
                "guide_action" => action,
                "topic" => topic,
                "revision" => current.revision
              },
              inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }
          ],
          log: false
        )

        guide_projection(current, actor)
    end
  end

  defp actor!(%SessionCredential{} = credential) do
    raw = SessionCredential.reveal(credential)

    with {:ok, s} <- Accounts.get_session_by_token(raw) do
      # Business/member-user locks precede the session row, as in RoleManagement.
      Repo.one(from x in WebSession, where: x.id == ^s.id, lock: "FOR UPDATE")

      case Accounts.get_session_by_token(raw) do
        {:ok, current} -> current
        _ -> Repo.rollback(:invalid_session)
      end
    else
      _ -> Repo.rollback(:invalid_session)
    end
  end

  defp actor!(_), do: Repo.rollback(:invalid_session)

  defp begin!(b, actor) do
    draft =
      Repo.insert!(
        %Draft{business_id: b.id, created_by_user_id: actor, proposal: Validation.empty()},
        log: false
      )

    audit!(draft, actor, nil)
    draft
  end

  defp change!(
         draft,
         actor,
         %{
           "revision" => revision,
           "request_id" => key,
           "state" => _state,
           "proposal" => _proposal
         } = attrs
       )
       when is_integer(revision) and revision >= 0 and map_size(attrs) in [4, 5] do
    with true <- not Map.has_key?(attrs, "confirm_review") or is_boolean(attrs["confirm_review"]),
         true <-
           Enum.all?(
             Map.keys(attrs),
             &(&1 in ~w(revision request_id state proposal confirm_review))
           ),
         {:ok, uuid} <- Ecto.UUID.cast(key) do
      hash = :crypto.hash(:sha256, :erlang.term_to_binary(attrs, [:deterministic]))

      case Repo.one(
             from r in "business_onboarding_receipts",
               where:
                 r.draft_id == ^draft.id and r.actor_user_id == ^actor and
                   r.request_id == type(^uuid, Ecto.UUID),
               select: %{hash: r.request_hash, result: r.result}
           ) do
        %{hash: ^hash, result: result} -> result
        %{} -> Repo.rollback(:request_conflict)
        nil -> save!(draft, actor, attrs, uuid, hash)
      end
    else
      _ -> Repo.rollback(:invalid_input)
    end
  end

  defp change!(_, _, _), do: Repo.rollback(:invalid_input)

  defp save!(draft, actor, attrs, uuid, hash) do
    if attrs["revision"] != draft.revision, do: Repo.rollback(:revision_conflict)

    unless Validation.valid?(attrs["proposal"], draft.business_id),
      do: Repo.rollback(:invalid_input)

    old = Enum.find_index(@states, &(&1 == draft.state))
    next = Enum.find_index(@states, &(&1 == attrs["state"]))

    unless next && abs(next - old) <= 1 && draft.state != "completed",
      do: Repo.rollback(:invalid_transition)

    if next > old do
      if next >= 2 and not Validation.locations_complete?(attrs["proposal"]),
        do: Repo.rollback(:incomplete_draft)

      if next >= 4 and
           not SchedulerApi.BusinessOnboarding.CatalogValidation.complete?(attrs["proposal"]),
         do: Repo.rollback(:incomplete_draft)

      if next >= 5 and
           not SchedulerApi.BusinessOnboarding.BrandingValidation.complete?(
             attrs["proposal"]["branding"]
           ),
         do: Repo.rollback(:incomplete_draft)

      if attrs["state"] in ~w(ready_to_publish completed) and attrs["confirm_review"] != true,
        do: Repo.rollback(:confirmation_required)
    end

    current =
      Repo.update!(
        Ecto.Changeset.change(draft,
          revision: draft.revision + 1,
          state: attrs["state"],
          proposal: attrs["proposal"]
        ),
        log: false
      )

    audit!(current, actor, draft.state)
    result = projection(current)

    Repo.insert_all(
      "business_onboarding_receipts",
      [
        %{
          draft_id: draft.id,
          actor_user_id: actor,
          request_id: Ecto.UUID.dump!(uuid),
          request_hash: hash,
          result: result,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ],
      log: false
    )

    result
  end

  defp projection(d),
    do: %{
      "schema_version" => d.schema_version,
      "revision" => d.revision,
      "state" => d.state,
      "proposal" => d.proposal,
      "readiness" => %{
        "draft_review_complete" => d.state == "completed",
        "services_configured" =>
          SchedulerApi.BusinessOnboarding.CatalogValidation.complete?(d.proposal),
        "branding_configured" =>
          SchedulerApi.BusinessOnboarding.BrandingValidation.complete?(d.proposal["branding"]),
        "published" => false,
        "blockers" => [
          "Proposals have not been applied",
          "Publication controls and booking policies require separate implementation"
        ]
      }
    }

  defp audit!(d, actor, previous) do
    Repo.insert_all(
      "business_onboarding_events",
      [
        %{
          draft_id: d.id,
          actor_user_id: actor,
          revision: d.revision,
          from_state: previous,
          to_state: d.state,
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ],
      log: false
    )
  end

  defp shops(id),
    do:
      Repo.all(
        from s in Shop,
          where: s.business_id == ^id and s.status == :active,
          order_by: s.id,
          select: %{id: s.id, name: s.name, timezone: s.timezone}
      )
end
