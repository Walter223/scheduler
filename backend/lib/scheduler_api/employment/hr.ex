defmodule SchedulerApi.Employment.HR do
  @moduledoc "Session-authorized, audited HR writes. No account linking, grants or employment termination."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, Shop, BusinessMembership, RoleAssignment}

  alias SchedulerApi.Employment.{
    EmploymentRecord,
    ShopAssignment,
    ClassificationHistory,
    HrAuditEvent,
    WorkShift
  }

  alias SchedulerApi.Appointments.JobAssignment
  @contact [:first_name, :last_name, :phone, :email, :home_address]
  @fields [
    :id,
    :business_id,
    :first_name,
    :last_name,
    :phone,
    :email,
    :home_address,
    :classification,
    :status,
    :starts_on,
    :ends_on
  ]
  @assignment_fields [:id, :employment_id, :business_id, :shop_id, :status, :starts_on, :ends_on]

  def create_employment(credential, business, attrs, opts \\ []),
    do: run(:create, credential, business, nil, attrs, opts)

  def update_contact(credential, employment, attrs, opts \\ []),
    do: run(:edit_contact, credential, employment, nil, attrs, opts)

  def change_classification(credential, employment, classification, opts \\ []),
    do: run(:change_classification, credential, employment, nil, classification, opts)

  def assign_shop(credential, employment, shop, attrs, opts \\ []),
    do: run(:assign_shop, credential, employment, shop, attrs, opts)

  def end_shop_assignment(credential, assignment, date, opts \\ []),
    do: run(:end_shop, credential, assignment, nil, date, opts)

  defp run(action, credential, ref, related, input, opts) do
    with {:ok, now} <- clock(opts) do
      case Repo.transaction(fn ->
             reference = reference(action, ref)

             business =
               if reference,
                 do: RoleManagement.lock_business(%Business{id: reference.business_id})

             actor = lock_actor(credential, business)

             allowed =
               not is_nil(actor) and not is_nil(business) and
                 Authorization.authorize(actor.user, :employment_manage, business) == :ok

             target =
               if allowed && reference.employment_id,
                 do:
                   Repo.one(
                     from e in EmploymentRecord,
                       where: e.id == ^reference.employment_id and e.business_id == ^business.id,
                       lock: "FOR UPDATE"
                   )

             assignment =
               if target && reference.assignment_id,
                 do:
                   Repo.one(
                     from a in ShopAssignment,
                       where: a.id == ^reference.assignment_id and a.employment_id == ^target.id,
                       lock: "FOR UPDATE"
                   )

             shop =
               if allowed && action in [:assign_shop, :end_shop],
                 do:
                   lock_shop(
                     if(assignment, do: %Shop{id: assignment.shop_id}, else: related),
                     business.id
                   )

             outcome =
               cond do
                 not allowed || (action != :create && is_nil(target)) -> {:error, :forbidden}
                 target && target.status != :active -> {:error, :employment_ended}
                 true -> apply_change(action, business, target, assignment, shop, input, now)
               end

             {status, reason, value, fields} =
               case outcome do
                 {:ok, value, fields} ->
                   {:applied,
                    %{
                      create: :created,
                      edit_contact: :updated,
                      change_classification: :reclassified,
                      assign_shop: :assigned,
                      end_shop: :ended
                    }[action], value, fields}

                 {:error, reason} ->
                   {:denied, reason, nil, []}
               end

             employment_id =
               if action == :create, do: value && value.id, else: target && target.id

             assigned =
               if status == :applied && action in [:assign_shop, :end_shop],
                 do: value,
                 else: assignment

             history_id =
               if status == :applied && action in [:create, :change_classification],
                 do:
                   Repo.one(
                     from h in ClassificationHistory,
                       where: h.employment_id == ^employment_id,
                       order_by: [desc: h.id],
                       limit: 1,
                       select: h.id
                   )

             persist!(
               Repo.insert(
                 %HrAuditEvent{
                   actor_user_id: actor && actor.user.id,
                   business_id: business && business.id,
                   employment_id: employment_id,
                   assignment_id: assigned && assigned.id,
                   shop_id: assigned && assigned.shop_id,
                   classification_history_id: history_id,
                   action: action,
                   outcome: status,
                   reason: Atom.to_string(reason),
                   changed_fields: Enum.map(fields, &Atom.to_string/1),
                   occurred_at: now
                 },
                 log: false
               )
             )

             if status == :applied,
               do:
                 {:ok,
                  Map.take(
                    value,
                    if(action in [:assign_shop, :end_shop], do: @assignment_fields, else: @fields)
                  )},
               else: {:error, reason}
           end) do
        {:ok, outcome} -> outcome
        {:error, _} -> {:error, :persistence_failed}
      end
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

  defp apply_change(:create, business, _, _, _, input, now) do
    with {:ok, params} <- params(input, @contact ++ [:classification, :starts_on]) do
      cs =
        %EmploymentRecord{business_id: business.id, inserted_at: now, updated_at: now}
        |> EmploymentRecord.creation_changeset(params)
        |> EmploymentRecord.contact_changeset(params)

      if cs.valid?,
        do:
          {:ok, persist!(Repo.insert(cs, log: false)),
           Enum.filter(@contact ++ [:classification, :starts_on], &Map.has_key?(params, &1))},
        else: {:error, :invalid_input}
    end
  end

  defp apply_change(:edit_contact, _, target, _, _, input, now) do
    with {:ok, params} <- params(input, @contact) do
      cs = EmploymentRecord.contact_changeset(target, params)

      cond do
        not cs.valid? ->
          {:error, :invalid_input}

        map_size(cs.changes) == 0 ->
          {:error, :unchanged}

        true ->
          {:ok,
           persist!(Repo.update(Ecto.Changeset.put_change(cs, :updated_at, now), log: false)),
           Map.keys(cs.changes)}
      end
    end
  end

  defp apply_change(:change_classification, _, target, _, _, input, now) do
    cs =
      target
      |> Ecto.Changeset.cast(%{classification: input}, [:classification])
      |> Ecto.Changeset.validate_required([:classification])

    cond do
      not cs.valid? ->
        {:error, :invalid_input}

      Ecto.Changeset.get_field(cs, :classification) == target.classification ->
        {:error, :unchanged}

      outstanding?(target.id, nil, nil) ->
        {:error, :outstanding_work}

      true ->
        {:ok, persist!(Repo.update(Ecto.Changeset.put_change(cs, :updated_at, now), log: false)),
         [:classification]}
    end
  end

  defp apply_change(:assign_shop, _, _, _, nil, _, _), do: {:error, :invalid_shop}

  defp apply_change(:assign_shop, _, target, _, shop, input, now) do
    with {:ok, params} <- params(input, [:starts_on]) do
      cs =
        ShopAssignment.creation_changeset(
          %ShopAssignment{
            employment_id: target.id,
            business_id: target.business_id,
            shop_id: shop.id,
            inserted_at: now,
            updated_at: now
          },
          params
        )

      cond do
        not cs.valid? ->
          {:error, :invalid_input}

        Date.compare(Ecto.Changeset.get_field(cs, :starts_on), target.starts_on) == :lt ->
          {:error, :invalid_date}

        Repo.exists?(
          from a in ShopAssignment,
            where: a.employment_id == ^target.id and a.shop_id == ^shop.id and a.status == :active
        ) ->
          {:error, :already_assigned}

        true ->
          {:ok, persist!(Repo.insert(cs, log: false)), [:starts_on]}
      end
    end
  end

  defp apply_change(:end_shop, _, _, _, nil, _, _), do: {:error, :invalid_shop}

  defp apply_change(:end_shop, _, target, assignment, shop, input, now) do
    with {:ok, date} <- date(input) do
      cond do
        assignment.status != :active ->
          {:error, :assignment_ended}

        Date.compare(date, assignment.starts_on) == :lt ->
          {:error, :invalid_date}

        outstanding?(target.id, assignment.id, {shop.timezone, date}) ->
          {:error, :outstanding_work}

        true ->
          {:ok,
           persist!(
             Repo.update(
               assignment
               |> ShopAssignment.end_changeset(date)
               |> Ecto.Changeset.put_change(:updated_at, now),
               log: false
             )
           ), [:ends_on]}
      end
    end
  end

  # Eligibility uses live database time, not the optional audit timestamp. Parent
  # employment locks serialize these checks against shift/job insertions. Existing
  # deferred termination primitives are deliberately not changed by HR shop ending.
  defp outstanding?(employment_id, assignment_id, local_end) do
    shifts = from w in WorkShift, where: w.employment_id == ^employment_id and w.status == :active

    jobs =
      from j in JobAssignment, where: j.employment_id == ^employment_id and j.status == :active

    {shifts, jobs} =
      if assignment_id,
        do:
          {where(shifts, [w], w.assignment_id == ^assignment_id),
           where(jobs, [j], j.assignment_id == ^assignment_id)},
        else: {shifts, jobs}

    shifts =
      case local_end do
        nil ->
          where(shifts, [w], w.ends_at > fragment("timezone('UTC',statement_timestamp())"))

        {zone, date} ->
          where(
            shifts,
            [w],
            w.ends_at > fragment("timezone('UTC',statement_timestamp())") or
              fragment(
                "((? - interval '1 microsecond') AT TIME ZONE 'UTC' AT TIME ZONE ?)::date",
                w.ends_at,
                ^zone
              ) > ^date
          )
      end

    Repo.exists?(shifts) or Repo.exists?(jobs)
  end

  defp reference(:create, %Business{id: id}) when is_integer(id),
    do: %{business_id: id, employment_id: nil, assignment_id: nil}

  defp reference(:end_shop, %ShopAssignment{id: id}) when is_integer(id),
    do:
      Repo.one(
        from a in ShopAssignment,
          where: a.id == ^id,
          select: %{
            business_id: a.business_id,
            employment_id: a.employment_id,
            assignment_id: a.id
          }
      )

  defp reference(action, %EmploymentRecord{id: id})
       when action in [:edit_contact, :change_classification, :assign_shop] and is_integer(id),
       do:
         Repo.one(
           from e in EmploymentRecord,
             where: e.id == ^id,
             select: %{
               business_id: e.business_id,
               employment_id: e.id,
               assignment_id: fragment("NULL::bigint")
             }
         )

  defp reference(_, _), do: nil

  defp lock_shop(%Shop{id: id}, business_id) when is_integer(id),
    do:
      Repo.one(
        from s in Shop,
          where: s.id == ^id and s.business_id == ^business_id and s.status == :active,
          lock: "FOR SHARE"
      )

  defp lock_shop(_, _), do: nil

  defp params(input, allowed) when is_map(input) do
    if Enum.all?(
         Map.keys(input),
         &(&1 in allowed or &1 in Enum.map(allowed, fn field -> Atom.to_string(field) end))
       ) and
         Enum.all?(
           allowed,
           &(not (Map.has_key?(input, &1) and Map.has_key?(input, Atom.to_string(&1))))
         ) do
      {:ok,
       Map.new(
         for field <- allowed,
             Map.has_key?(input, field) or Map.has_key?(input, Atom.to_string(field)),
             do: {field, Map.get(input, field, Map.get(input, Atom.to_string(field)))}
       )}
    else
      {:error, :invalid_input}
    end
  end

  defp params(_, _), do: {:error, :invalid_input}
  defp date(%Date{} = date), do: {:ok, date}

  defp date(value) when is_binary(value) and byte_size(value) == 10 do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp date(_), do: {:error, :invalid_date}

  defp lock_actor(%SessionCredential{} = credential, business) do
    token = SessionCredential.reveal(credential)

    with {:ok, session} <- Accounts.get_session_by_token(token) do
      Repo.one(from u in User, where: u.id == ^session.user_id, lock: "FOR UPDATE")
      Repo.one(from s in WebSession, where: s.id == ^session.id, lock: "FOR UPDATE")

      if business do
        member =
          Repo.one(
            from m in BusinessMembership,
              where: m.user_id == ^session.user_id and m.business_id == ^business.id,
              lock: "FOR SHARE"
          )

        if member,
          do:
            Repo.all(
              from r in RoleAssignment,
                where: r.membership_id == ^member.id,
                order_by: r.id,
                lock: "FOR SHARE"
            )
      end

      case Accounts.get_session_by_token(token) do
        {:ok, current} -> current
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp lock_actor(_, _), do: nil
  defp persist!({:ok, value}), do: value
  defp persist!({:error, _}), do: Repo.rollback(:persistence_failed)

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :now)),
      do: SchedulerApi.Authentication.now(opts),
      else: {:error, :invalid_options}
  end

  defp clock(_), do: {:error, :invalid_options}
end
