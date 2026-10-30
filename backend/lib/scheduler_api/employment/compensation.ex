defmodule SchedulerApi.Employment.Compensation do
  @moduledoc "Authorized pay projections and audited, append-only rate changes. No payroll or HTTP API."
  import Ecto.Query
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Accounts.{SessionCredential, User, WebSession}
  alias SchedulerApi.Authorization.RoleManagement
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}
  alias SchedulerApi.Employment.{EmploymentRecord, CompensationRate, CompensationAuditEvent}

  @doc "HR or assigned-Detailer current rate only; no Employee grant can read somebody else's pay."
  def get_current_rate(user, employment, opts \\ []) do
    with {:ok, now} <- clock(opts) do
      allowed =
        read_targets(
          user,
          employment,
          [:compensation_read, :assigned_employee_compensation_read],
          now
        )

      if Repo.exists?(allowed),
        do: {:ok, allowed |> current_rates(now) |> Repo.one() |> project()},
        else: {:error, :forbidden}
    end
  end

  @doc "Business Owner/Manager history, including former employment; Owner-pay restrictions still apply."
  def list_rate_history(user, employment, opts \\ []) do
    with {:ok, now} <- clock(opts) do
      allowed = read_targets(user, employment, [:compensation_read], now)

      if Repo.exists?(allowed) do
        rows = allowed |> rates() |> order_by([r], asc: r.effective_from, asc: r.id) |> Repo.all()
        {:ok, Enum.map(rows, &project/1)}
      else
        {:error, :forbidden}
      end
    end
  end

  @doc "Own current pay only, from explicit linked identity and an own-pay grant."
  def get_own_current_rate(user, business, opts \\ [])

  def get_own_current_rate(%User{id: id} = user, %Business{id: business_id}, opts)
      when is_integer(id) and is_integer(business_id) do
    with {:ok, now} <- clock(opts) do
      scopes =
        Authorization.authorized_compensation_employment_ids_query(
          user,
          :compensation_own_read,
          now
        )

      allowed =
        from e in EmploymentRecord,
          join: p in subquery(scopes),
          on: p.id == e.id,
          where: e.user_id == ^id and e.business_id == ^business_id,
          distinct: true,
          select: %{id: e.id, business_id: e.business_id}

      if Repo.exists?(allowed),
        do: {:ok, allowed |> current_rates(now) |> Repo.one() |> project()},
        else: {:error, :forbidden}
    end
  end

  def get_own_current_rate(_, _, _), do: {:error, :forbidden}

  @doc "Requires an actual opaque SessionCredential. Appends chronologically; rates are never replaced."
  def set_rate(credential, employment, attrs, opts \\ []) do
    with {:ok, now} <- clock(opts) do
      result =
        Repo.transaction(fn ->
          reference = target_reference(employment)

          business =
            if reference, do: RoleManagement.lock_business(%Business{id: reference.business_id})

          actor = lock_actor(credential, business)

          target =
            if reference,
              do:
                Repo.one(
                  from e in EmploymentRecord,
                    where: e.id == ^reference.id and e.business_id == ^reference.business_id,
                    lock: "FOR UPDATE",
                    select: struct(e, [:id, :business_id, :status, :starts_on])
                )

          outcome =
            cond do
              is_nil(target) or is_nil(actor) or is_nil(business) or
                  Authorization.authorize(actor.user, :compensation_write, target) != :ok ->
                {:error, :forbidden}

              target.status != :active ->
                {:error, :employment_ended}

              true ->
                append_rate(target, attrs, now)
            end

          event =
            case outcome do
              {:ok, rate, closed} ->
                %CompensationAuditEvent{
                  actor_user_id: actor.user.id,
                  business_id: target.business_id,
                  employment_id: target.id,
                  rate_id: rate.id,
                  closed_rate_id: closed && closed.id,
                  closed_effective_until: closed && rate.effective_from,
                  outcome: :applied,
                  reason: :created,
                  occurred_at: now
                }

              {:error, reason} ->
                %CompensationAuditEvent{
                  actor_user_id: actor && actor.user.id,
                  business_id: target && target.business_id,
                  employment_id: target && target.id,
                  outcome: :denied,
                  reason: reason,
                  occurred_at: now
                }
            end

          # Expected denials commit only an audit event; mutation+audit succeed or
          # roll back together. No financial values or credentials enter this event.
          case Repo.insert(event, log: false) do
            {:ok, _} ->
              case outcome do
                {:ok, rate, _} -> {:ok, project(rate)}
                error -> error
              end

            {:error, _} ->
              Repo.rollback(:persistence_failed)
          end
        end)

      case result do
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

  defp append_rate(target, attrs, now) do
    cs =
      CompensationRate.creation_changeset(
        %CompensationRate{
          business_id: target.business_id,
          employment_id: target.id,
          inserted_at: now
        },
        attrs
      )

    latest =
      Repo.one(
        from r in CompensationRate,
          where: r.employment_id == ^target.id,
          order_by: [desc: r.effective_from, desc: r.id],
          limit: 1
      )

    today = today(now)
    candidate = Ecto.Changeset.apply_changes(cs)

    cond do
      not cs.valid? ->
        {:error, :invalid_input}

      Date.compare(candidate.effective_from, today) == :lt or
          Date.compare(candidate.effective_from, target.starts_on) == :lt ->
        {:error, :invalid_effective_date}

      candidate.effective_until &&
          Date.compare(candidate.effective_until, candidate.effective_from) != :gt ->
        {:error, :invalid_effective_date}

      latest &&
          (Date.compare(candidate.effective_from, latest.effective_from) != :gt or
             (latest.effective_until &&
                Date.compare(candidate.effective_from, latest.effective_until) == :lt)) ->
        {:error, :effective_date_conflict}

      true ->
        # Expected validation denials happen before mutation. Unexpected DB
        # rejection must abort the entire transaction, including any closure;
        # nested Ecto transactions are NOT independent savepoints.
        closed =
          if latest && is_nil(latest.effective_until) do
            case latest
                 |> CompensationRate.close_changeset(candidate.effective_from)
                 |> Repo.update(log: false) do
              {:ok, value} -> value
              {:error, _} -> Repo.rollback(:persistence_failed)
            end
          end

        case Repo.insert(cs, log: false) do
          {:ok, rate} -> {:ok, rate, closed}
          {:error, _} -> Repo.rollback(:persistence_failed)
        end
    end
  end

  defp lock_actor(%SessionCredential{} = credential, business) do
    token = SessionCredential.reveal(credential)

    with {:ok, session} <- Accounts.get_session_by_token(token) do
      # Business -> user -> session -> membership -> grants -> employment.
      # Business locking coordinates with RoleManagement; user/session locks match
      # Accounts revocation. Only current persisted eligibility is authoritative.
      Repo.one(from u in User, where: u.id == ^session.user_id, lock: "FOR UPDATE")
      Repo.one(from s in WebSession, where: s.id == ^session.id, lock: "FOR UPDATE")

      if business do
        membership =
          Repo.one(
            from m in BusinessMembership,
              where: m.user_id == ^session.user_id and m.business_id == ^business.id,
              lock: "FOR SHARE"
          )

        if membership,
          do:
            Repo.all(
              from r in RoleAssignment,
                where: r.membership_id == ^membership.id,
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

  defp target_reference(%EmploymentRecord{id: id}) when is_integer(id) and id > 0,
    do:
      Repo.one(
        from e in EmploymentRecord,
          where: e.id == ^id,
          select: %{id: e.id, business_id: e.business_id}
      )

  defp target_reference(_), do: nil

  defp read_targets(user, %EmploymentRecord{id: id}, actions, now) when is_integer(id) do
    [action | rest] = actions
    first = Authorization.authorized_compensation_employment_ids_query(user, action, now)

    query =
      from e in EmploymentRecord,
        where: e.id == ^id and e.id in subquery(from p in subquery(first), select: p.id),
        select: %{id: e.id, business_id: e.business_id}

    case rest do
      [] ->
        query

      [other] ->
        second = Authorization.authorized_compensation_employment_ids_query(user, other, now)

        from e in query,
          or_where: e.id == ^id and e.id in subquery(from p in subquery(second), select: p.id)
    end
  end

  defp read_targets(_, _, _, _),
    do: from(e in EmploymentRecord, where: false, select: %{id: e.id, business_id: e.business_id})

  defp rates(allowed) do
    from r in CompensationRate,
      join: p in subquery(allowed),
      on: p.id == r.employment_id and p.business_id == r.business_id,
      select:
        map(r, [
          :id,
          :employment_id,
          :business_id,
          :pay_basis,
          :currency,
          :amount,
          :effective_from,
          :effective_until
        ])
  end

  defp current_rates(allowed, now) do
    date = today(now)

    from [r, p] in rates(allowed),
      join: e in EmploymentRecord,
      on: e.id == r.employment_id,
      where:
        e.status == :active and e.starts_on <= ^date and r.effective_from <= ^date and
          (is_nil(r.effective_until) or r.effective_until > ^date)
  end

  defp project(nil), do: nil

  defp project(rate) do
    rate
    |> Map.take([
      :id,
      :employment_id,
      :business_id,
      :pay_basis,
      :currency,
      :amount,
      :effective_from,
      :effective_until
    ])
    |> Map.update!(:amount, &Decimal.to_string(Decimal.round(&1, 2), :normal))
  end

  defp today(now) do
    %{rows: [[date]]} =
      Repo.query!("SELECT ($1::timestamptz AT TIME ZONE 'America/Denver')::date", [now],
        log: false
      )

    date
  end

  defp clock(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 == :now)),
      do: SchedulerApi.Authentication.now(opts),
      else: {:error, :invalid_options}
  end

  defp clock(_), do: {:error, :invalid_options}
end
