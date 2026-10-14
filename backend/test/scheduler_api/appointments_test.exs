defmodule SchedulerApi.AppointmentsTest do
  use SchedulerApi.DataCase, async: true

  alias SchedulerApi.{Appointments, Catalog}
  alias SchedulerApi.Appointments.Appointment
  import SchedulerApi.CatalogFixtures

  setup do
    price = service_price_fixture()

    attrs = %{
      service_price_id: price.id,
      starts_at: ~U[2026-11-01 16:00:00Z],
      customer_name: "Alex Driver",
      customer_email: "alex@example.com",
      customer_phone: "+1 303 555 0100",
      vehicle_make: "Toyota",
      vehicle_model: "Camry"
    }

    %{price: price, attrs: attrs}
  end

  test "creates a pending appointment with catalog snapshots and optional notes", %{
    attrs: attrs,
    price: price
  } do
    assert {:ok, appointment} =
             Appointments.create_appointment(Map.put(attrs, :notes, "Please call on arrival"))

    assert appointment.service_price_id == price.id
    assert appointment.starts_at == attrs.starts_at
    assert appointment.price_cents == price.price_cents
    assert appointment.duration_minutes == price.duration_minutes
    assert appointment.status == :pending
    assert appointment.notes == "Please call on arrival"

    for field <- [:customer_name, :customer_email, :customer_phone, :vehicle_make, :vehicle_model] do
      assert Map.fetch!(appointment, field) == Map.fetch!(attrs, field)
    end
  end

  test "ignores caller-supplied snapshots and status with string keys", %{
    attrs: attrs,
    price: price
  } do
    attrs = Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)

    attrs =
      Map.merge(attrs, %{"price_cents" => 1, "duration_minutes" => 1, "status" => "confirmed"})

    assert {:ok, appointment} = Appointments.create_appointment(attrs)
    assert appointment.price_cents == price.price_cents
    assert appointment.duration_minutes == price.duration_minutes
    assert appointment.status == :pending
    assert appointment.notes == nil
  end

  test "catalog updates do not alter existing snapshots", %{attrs: attrs, price: price} do
    assert {:ok, appointment} = Appointments.create_appointment(attrs)

    assert {:ok, _} =
             Catalog.update_service_price(price, %{price_cents: 9999, duration_minutes: 120})

    stored = Appointments.get_appointment!(appointment.id)
    assert stored.price_cents == price.price_cents
    assert stored.duration_minutes == price.duration_minutes
    assert {:ok, next} = Appointments.create_appointment(attrs)
    assert next.price_cents == 9999
    assert next.duration_minutes == 120
  end

  test "retrieves appointments in chronological order and handles missing IDs", %{attrs: attrs} do
    assert {:ok, later} = Appointments.create_appointment(attrs)

    assert {:ok, earlier} =
             Appointments.create_appointment(%{attrs | starts_at: ~U[2026-10-31 16:00:00Z]})

    assert Appointments.list_appointments() == [earlier, later]
    assert Appointments.get_appointment(later.id) == later
    assert Appointments.get_appointment(-1) == nil
    assert_raise Ecto.NoResultsError, fn -> Appointments.get_appointment!(-1) end
  end

  test "requires selection, start time, and customer/vehicle fields", %{attrs: attrs} do
    for field <- Map.keys(attrs) do
      assert {:error, changeset} = Appointments.create_appointment(Map.delete(attrs, field))
      assert "can't be blank" in Map.fetch!(errors_on(changeset), field)
    end

    assert Appointments.list_appointments() == []
  end

  test "rejects blank details, bad email, malformed time, and invalid selection", %{attrs: attrs} do
    for field <- [:customer_name, :customer_phone, :vehicle_make, :vehicle_model] do
      assert {:error, changeset} = Appointments.create_appointment(Map.put(attrs, field, "  "))
      assert "can't be blank" in Map.fetch!(errors_on(changeset), field)
    end

    for {field, value} <- [
          customer_email: "invalid",
          starts_at: "invalid",
          service_price_id: "invalid",
          service_price_id: -1
        ] do
      assert {:error, changeset} = Appointments.create_appointment(Map.put(attrs, field, value))
      assert Map.has_key?(errors_on(changeset), field)
    end
  end

  test "schema validates snapshots and maps foreign key violations", %{attrs: attrs} do
    changeset = Appointment.changeset(%Appointment{price_cents: 0, duration_minutes: 0}, attrs)
    assert "must be greater than 0" in errors_on(changeset).price_cents
    assert "must be greater than 0" in errors_on(changeset).duration_minutes

    changeset =
      Appointment.changeset(%Appointment{price_cents: 100, duration_minutes: 30}, %{
        attrs
        | service_price_id: -1
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert "does not exist" in errors_on(changeset).service_price_id
  end

  test "database enforces snapshot, status, and nonblank constraints", %{attrs: attrs} do
    assert {:ok, appointment} = Appointments.create_appointment(attrs)

    for {field, value} <- [
          price_cents: 0,
          duration_minutes: 0,
          status: "invalid",
          customer_name: " "
        ] do
      # Raw SQL bypasses schema validation to verify the database constraints.
      query_options = [mode: :savepoint]

      assert {:error, %Postgrex.Error{postgres: error}} =
               Repo.query(
                 "UPDATE appointments SET #{field} = $1 WHERE id = $2",
                 [value, appointment.id],
                 query_options
               )

      assert error.code == :check_violation
      assert error.constraint == to_string(constraint_name(field))
    end
  end

  test "referenced service prices cannot be deleted", %{attrs: attrs, price: price} do
    assert {:ok, _} = Appointments.create_appointment(attrs)

    changeset =
      Ecto.Changeset.change(price)
      |> foreign_key_constraint(:id, name: :appointments_service_price_id_fkey)

    assert {:error, changeset} = Repo.delete(changeset)
    assert Map.has_key?(errors_on(changeset), :id)
  end

  defp constraint_name(:price_cents), do: :appointments_price_positive
  defp constraint_name(:duration_minutes), do: :appointments_duration_positive
  defp constraint_name(:status), do: :appointments_status_valid
  defp constraint_name(:customer_name), do: :appointments_customer_name_not_blank
end
