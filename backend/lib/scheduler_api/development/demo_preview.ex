defmodule SchedulerApi.Development.DemoPreview do
  @moduledoc "Explicit operator demo fixture. No identities, grants, notifications or external systems."
  import Ecto.Query
  alias SchedulerApi.{Repo, Accounts, Authorization, Appointments, Catalog}
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.Employment.{HR, EmploymentRecord, ShopAssignment, WorkSchedules}
  alias SchedulerApi.Appointments.{Availability, Appointment, JobAssignments}
  @marker "magnum-demo-preview-v1"
  def marker, do: @marker

  def plan(user_id, business_id) do
    user = Repo.get!(User, user_id)
    business = Repo.get!(Business, business_id)
    :ok = Authorization.authorize(user, :access_manage, business)
    :ok = Authorization.authorize(user, :employment_manage, business)
    shops = Repo.all(from s in Shop, where: s.business_id == ^business_id and s.slug in ^slugs())

    if shops != [] do
      unless length(shops) == 2 and Enum.all?(shops, &String.starts_with?(&1.name, "DEMO · ")),
        do: raise("Demo identifier collision; refusing writes")

      %{
        mode: :existing,
        shop_ids: Enum.map(shops, & &1.id),
        message:
          "No writes; existing fixture retained. Dates are never rolled forward automatically."
      }
    else
      today = DateTime.utc_now() |> Availability.local_datetime() |> NaiveDateTime.to_date()
      date = choose_date(today)

      %{
        mode: :create,
        date: date,
        shops: ["DEMO · Aurora Studio", "DEMO · Lakewood Studio"],
        employees: [
          "Demo Alex Rivera",
          "Demo Bea Chen",
          "Demo Casey Morgan",
          "Demo Jordan Ellis (Shop Manager)",
          "Demo Sam Brooks (Former)"
        ],
        shifts: 3,
        appointments: 6,
        crew_sizes: [2, 1, 0, 1, 0, 0],
        message:
          "New demo-owned rows only. No canceled appointment: no supported cancellation workflow."
      }
    end
  end

  def apply(user_id, business_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.one!(from b in Business, where: b.id == ^business_id, lock: "FOR UPDATE")
        plan = plan(user_id, business_id)

        if plan.mode == :existing do
          plan
        else
          user = Repo.get!(User, user_id)
          {:ok, session, credential} = Accounts.create_session(user)
          result = seed(credential, Repo.get!(Business, business_id), plan)
          {:ok, _} = Accounts.revoke_session(session, :logout)
          result
        end
      end)

    result
  end

  def verify(user_id, business_id) do
    user = Repo.get!(User, user_id)

    shops =
      Repo.all(
        from s in Shop,
          where: s.business_id == ^business_id and s.slug in ^slugs(),
          order_by: s.id
      )

    for shop <- shops do
      {:ok, _} = SchedulerApi.Appointments.Dashboard.read(user, business_id, shop.id)

      bookings =
        Repo.all(from a in Appointment, where: a.shop_id == ^shop.id, order_by: a.starts_at)

      for a <- bookings do
        {:ok, _} = JobAssignments.list_team(user, a)
      end

      if bookings != [] do
        date =
          hd(bookings).starts_at
          |> Availability.local_datetime()
          |> NaiveDateTime.to_date()
          |> Date.to_iso8601()

        {:ok, _} =
          SchedulerApi.Appointments.Calendar.read(user, business_id, %{
            "date" => date,
            "days" => "7",
            "shop_id" => Integer.to_string(shop.id)
          })
      end
    end

    {:ok, _} = SchedulerApi.Employment.list_business_roster(user, %Business{id: business_id})
    {:ok, _} = HR.list_former_employees(user, %Business{id: business_id})

    employees =
      Repo.all(
        from e in EmploymentRecord,
          where: e.business_id == ^business_id and like(e.email, "%@demo.magnum.invalid")
      )

    for e <- employees, do: {:ok, _} = HR.list_employment_history(user, e)
    %{shops: length(shops), employment_records: length(employees), authorized_reads: :passed}
  end

  defp seed(credential, business, plan) do
    shops =
      for {slug, name} <- Enum.zip(slugs(), plan.shops) do
        %Shop{business_id: business.id}
        |> Shop.changeset(%{slug: slug, name: name, timezone: "America/Denver"})
        |> Repo.insert!()
      end

    [a, b] = shops

    employees =
      for {first, last, classification} <- [
            {"Demo Alex", "Rivera", :detailer},
            {"Demo Bea", "Chen", :detailer},
            {"Demo Casey", "Morgan", :detailer},
            {"Demo Jordan", "Ellis", :shop_manager},
            {"Demo Sam", "Brooks", :detailer}
          ] do
        {:ok, dto} =
          HR.create_employment(credential, business, %{
            first_name: first,
            last_name: last,
            classification: classification,
            starts_on: Date.add(plan.date, -60),
            email: String.downcase(last) <> "@demo.magnum.invalid",
            phone: "303-555-0100",
            home_address: "Fictional demo address"
          })

        Repo.get!(EmploymentRecord, dto.id)
      end

    [alex, bea, casey, manager, former] = employees

    assignments =
      for {e, shop} <- [
            {alex, a},
            {alex, b},
            {bea, a},
            {casey, b},
            {manager, a},
            {manager, b},
            {former, a}
          ] do
        {:ok, dto} = HR.assign_shop(credential, e, shop, %{starts_on: Date.add(plan.date, -30)})
        {{e.id, shop.id}, Repo.get!(ShopAssignment, dto.id)}
      end
      |> Map.new()

    {:ok, _} = HR.terminate_employment(credential, former)
    {opens, closes} = Availability.business_hours(plan.date)

    for {e, shop} <- [{alex, a}, {bea, a}, {casey, b}] do
      {:ok, _} =
        WorkSchedules.create_shift(credential, assignments[{e.id, shop.id}], %{
          starts_at: opens,
          ends_at: closes
        })
    end

    # Catalog changesets enforce business ownership; no default-shop helpers are used.
    service =
      %Catalog.Service{business_id: business.id}
      |> Catalog.Service.changeset(%{name: "DEMO Express Detail", description: @marker})
      |> Repo.insert!()

    size =
      %Catalog.VehicleSize{business_id: business.id}
      |> Catalog.VehicleSize.changeset(%{name: "DEMO Sedan", sort_order: 900_001})
      |> Repo.insert!()

    for shop <- shops do
      {:ok, price} =
        Catalog.create_service_price(shop, %{
          service_id: service.id,
          vehicle_size_id: size.id,
          price_cents: 6500,
          duration_minutes: 30
        })

      {:ok, availability} = Availability.get_for_shop(shop, Date.to_iso8601(plan.date), price.id)

      starts =
        Enum.take(availability.available_times, 3)
        |> Enum.with_index()
        |> Enum.map(fn {_, i} ->
          DateTime.add(opens, (slot_offset(availability.available_times) + i * 60) * 60)
        end)

      unless length(starts) == 3, do: raise("Not enough valid demo slots")

      for {starts_at, index} <- Enum.with_index(starts) do
        {:ok, booking} =
          Appointments.create_appointment(shop, %{
            service_price_id: price.id,
            starts_at: starts_at,
            customer_first_name: "Demo",
            customer_last_name: Enum.at(["Taylor", "Parker", "Avery"], index),
            customer_email: "driver#{index}@demo.magnum.invalid",
            customer_phone: "303-555-0110",
            vehicle_make: "Toyota",
            vehicle_model: "Camry",
            notes: @marker
          })

        crew =
          cond do
            shop.id == a.id and index == 0 -> [alex, bea]
            shop.id == a.id and index == 1 -> [alex]
            shop.id == b.id and index == 0 -> [casey]
            true -> []
          end

        for {e, i} <- Enum.with_index(crew) do
          {:ok, job} =
            JobAssignments.add_member(credential, booking, assignments[{e.id, shop.id}])

          if i == 0 do
            {:ok, _} =
              JobAssignments.designate_lead(
                credential,
                booking,
                %SchedulerApi.Appointments.JobAssignment{id: job.id}
              )
          end
        end
      end
    end

    %{
      mode: :created,
      date: plan.date,
      shop_ids: Enum.map(shops, & &1.id),
      employment_ids: Enum.map(employees, & &1.id),
      appointments: 6
    }
  end

  defp slot_offset([first | _]) do
    [h, m] = String.split(first, ":") |> Enum.map(&String.to_integer/1)
    (h - 9) * 60 + m
  end

  defp slugs, do: [@marker <> "-aurora", @marker <> "-lakewood"]

  defp choose_date(date) do
    local = Availability.local_datetime(DateTime.utc_now())

    cond do
      Date.day_of_week(date) == 7 ->
        Date.add(date, 1)

      date == NaiveDateTime.to_date(local) and
          Time.compare(NaiveDateTime.to_time(local), ~T[14:00:00]) == :gt ->
        choose_date(Date.add(date, 1))

      true ->
        date
    end
  end
end
