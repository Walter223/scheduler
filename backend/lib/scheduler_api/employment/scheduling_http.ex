defmodule SchedulerApi.Employment.SchedulingHTTP do
  @moduledoc "Scoped HTTP references/fields; mutations delegate exclusively to scheduling contexts."
  import Ecto.Query
  alias SchedulerApi.{Repo, Authorization, Appointments}
  alias SchedulerApi.Organizations.{Shop, Business}
  alias SchedulerApi.Employment.{WorkSchedules, WorkShift, EmploymentRecord, ShopAssignment}
  alias SchedulerApi.Appointments.{Appointment, JobAssignment, JobAssignments}

  def run(action, session, credential, path, body, query) do
    with {:ok, biz} <- id(path["business_id"]) do
      if action in [:own_jobs, :own_shifts] do
        with {:ok, opts} <- options(query, action) do
          if action == :own_jobs,
            do: JobAssignments.list_own_work(session.user, %Business{id: biz}, opts),
            else: WorkSchedules.list_own_shifts(session.user, %Business{id: biz}, opts)
        end
      else
        with {:ok, shop_id} <- id(path["shop_id"]),
             %Shop{} = shop <-
               Repo.one(from s in Shop, where: s.id == ^shop_id and s.business_id == ^biz),
             :ok <- Authorization.authorize(session.user, permission(action), shop),
             {:ok, opts} <- options(query, action),
             :ok <- payload(body, fields(action)) do
          invoke(action, session, credential, shop, path, body, opts)
        else
          nil -> {:error, :forbidden}
          error -> error
        end
      end
    end
  end

  defp permission(:appointments), do: :appointments_read
  defp permission(a) when a in [:team, :add, :remove, :lead, :clear_lead], do: :jobs_assign
  defp permission(_), do: :schedule_manage

  defp invoke(:appointments, s, _, shop, _, _, opts),
    do: Appointments.list_authorized_shop_appointments(s, shop, opts)

  defp invoke(:shifts, s, _, shop, _, _, opts),
    do: WorkSchedules.list_shop_shifts(s.user, shop, opts)

  defp invoke(:employee_shifts, s, _, shop, path, _, opts) do
    with {:ok, e} <- period(shop, path),
         true <-
           Repo.exists?(
             from a in ShopAssignment,
               where:
                 a.employment_id == ^e.id and a.shop_id == ^shop.id and
                   a.business_id == ^shop.business_id
           ) do
      WorkSchedules.list_employee_shifts(s.user, shop, e, opts)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp invoke(a, s, c, shop, path, body, opts)
       when a in [:team, :add, :remove, :lead, :clear_lead] do
    with {:ok, id} <- id(path["appointment_id"]),
         %Appointment{} = booking <-
           Repo.one(
             from a in Appointment,
               where: a.id == ^id and a.business_id == ^shop.business_id and a.shop_id == ^shop.id
           ) do
      case a do
        :team ->
          JobAssignments.list_team(s.user, booking, opts)

        :add ->
          with {:ok, assigned} <- assignment(shop, body),
               do: JobAssignments.add_member(c, booking, assigned)

        :clear_lead ->
          JobAssignments.clear_lead(c, booking)

        other ->
          with {:ok, job_id} <- id(path["job_id"]),
               %JobAssignment{} = job <-
                 Repo.one(
                   from j in JobAssignment,
                     where:
                       j.id == ^job_id and j.appointment_id == ^booking.id and
                         j.shop_id == ^shop.id and j.business_id == ^shop.business_id
                 ) do
            if other == :remove,
              do: JobAssignments.remove_member(c, booking, job),
              else: JobAssignments.designate_lead(c, booking, job)
          else
            nil -> {:error, :forbidden}
            error -> error
          end
      end
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp invoke(:create_shift, _, c, shop, _, body, _) do
    with {:ok, a} <- assignment(shop, body),
         do: WorkSchedules.create_shift(c, a, Map.take(body, ["starts_at", "ends_at"]))
  end

  defp invoke(action, _, c, shop, path, body, _)
       when action in [:cancel_shift, :reschedule_shift] do
    with {:ok, id} <- id(path["shift_id"]),
         %WorkShift{} = w <-
           Repo.one(
             from w in WorkShift,
               where: w.id == ^id and w.shop_id == ^shop.id and w.business_id == ^shop.business_id
           ) do
      if action == :cancel_shift,
        do: WorkSchedules.cancel_shift(c, w),
        else: WorkSchedules.reschedule_shift(c, w, body)
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp period(shop, p) do
    with {:ok, employee} <- id(p["employee_id"]),
         {:ok, id} <- id(p["period_id"]),
         %EmploymentRecord{} = e <-
           Repo.one(
             from e in EmploymentRecord,
               where:
                 e.id == ^id and e.employee_id == ^employee and e.business_id == ^shop.business_id
           ) do
      {:ok, e}
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp assignment(shop, b) do
    with {:ok, e} <- period(shop, b),
         {:ok, id} <- id(b["assignment_id"]),
         %ShopAssignment{} = a <-
           Repo.one(
             from a in ShopAssignment,
               where:
                 a.id == ^id and a.employment_id == ^e.id and a.business_id == ^shop.business_id and
                   a.shop_id == ^shop.id
           ) do
      {:ok, a}
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp fields(:create_shift), do: ~w(employee_id period_id assignment_id starts_at ends_at)
  defp fields(:add), do: ~w(employee_id period_id assignment_id)
  defp fields(:reschedule_shift), do: ~w(starts_at ends_at)
  defp fields(_), do: []

  defp payload(b, allowed) when is_map(b),
    do: if(Enum.all?(Map.keys(b), &(&1 in allowed)), do: :ok, else: {:error, :invalid_input})

  defp payload(_, _), do: {:error, :invalid_input}

  defp options(q, a) do
    reads = [:appointments, :team, :shifts, :employee_shifts, :own_jobs, :own_shifts]

    allowed =
      if a in [:shifts, :employee_shifts, :own_shifts],
        do: ~w(limit cursor from until),
        else: if(a in reads, do: ~w(limit cursor), else: [])

    if Enum.all?(Map.keys(q), &(&1 in allowed)) do
      Enum.reduce_while(q, {:ok, []}, fn {key, value}, {:ok, opts} ->
        case key do
          "limit" ->
            case id(value) do
              {:ok, n} when n <= 100 -> {:cont, {:ok, [{:limit, n} | opts]}}
              _ -> {:halt, {:error, :invalid_input}}
            end

          "cursor" ->
            {:cont, {:ok, [{:cursor, value} | opts]}}

          "from" ->
            {:cont, {:ok, [{:from, value} | opts]}}

          "until" ->
            {:cont, {:ok, [{:until, value} | opts]}}
        end
      end)
    else
      {:error, :invalid_input}
    end
  end

  defp id(v) when is_integer(v) and v > 0 and v <= 9_223_372_036_854_775_807, do: {:ok, v}

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} -> id(n)
      _ -> {:error, :invalid_input}
    end
  end

  defp id(_), do: {:error, :invalid_input}
end
