defmodule SchedulerApi.AccountsTest do
  use SchedulerApi.DataCase, async: true
  alias SchedulerApi.Accounts
  alias SchedulerApi.Accounts.{User, VerifiedIdentity, WebSession}
  import SchedulerApi.AccountsFixtures
  @now ~U[2026-10-28 12:00:00Z]

  test "only the internal VerifiedIdentity is accepted, never claims/params maps" do
    identity = verified_identity_fixture()

    assert {:error, :unverified_identity} =
             Accounts.sync_verified_identity(Map.from_struct(identity))

    assert {:error, :unverified_identity} =
             Accounts.sync_verified_identity(%{"sub" => "unverified"})

    assert {:error, :unverified_identity} =
             Accounts.sync_verified_identity(%{identity | email_verified: "true"})

    assert Repo.aggregate(User, :count) == 0
  end

  test "unknown identity creates pending user with opaque, unmodified subject and deterministic timestamps" do
    identity =
      verified_identity_fixture(%{
        subject: "opaque/not-a-uuid|Case Sensitive ",
        authenticated_at: DateTime.add(@now, -60)
      })

    assert {:ok, user} = Accounts.sync_verified_identity(identity, now: @now)
    assert user.status == :pending
    assert user.keycloak_issuer == identity.issuer
    assert user.keycloak_subject == identity.subject
    assert user.profile_synced_at == @now
    assert user.last_authenticated_at == DateTime.add(@now, -60)
    assert user.inserted_at == @now
    assert user.updated_at == @now
    assert Repo.aggregate(WebSession, :count) == 0
  end

  test "profile/email changes preserve ID, creation timestamp and identity key" do
    identity = verified_identity_fixture()
    assert {:ok, original} = Accounts.sync_verified_identity(identity, now: @now)
    later = DateTime.add(@now, 60)

    assert {:ok, updated} =
             Accounts.sync_verified_identity(
               %{
                 identity
                 | email: "changed@example.invalid",
                   first_name: "Changed",
                   last_name: nil,
                   email_verified: false
               },
               now: later
             )

    assert updated.id == original.id
    assert updated.inserted_at == original.inserted_at
    assert updated.email == "changed@example.invalid"
    refute updated.email_verified
    assert updated.first_name == "Changed"
    assert is_nil(updated.last_name)
    assert updated.profile_synced_at == later
    assert updated.last_authenticated_at == later
    assert Repo.aggregate(User, :count) == 1
  end

  test "same email never merges different subjects or issuers" do
    identity = verified_identity_fixture()
    {:ok, first} = Accounts.sync_verified_identity(identity, now: @now)

    {:ok, second} =
      Accounts.sync_verified_identity(%{identity | subject: "another-subject"}, now: @now)

    {:ok, third} =
      Accounts.sync_verified_identity(
        %{identity | issuer: "https://another.example.invalid/realm"},
        now: @now
      )

    assert length(Enum.uniq([first.id, second.id, third.id])) == 3
    assert Repo.aggregate(User, :count) == 3
  end

  for status <- [:pending, :active, :suspended, :deactivated] do
    test "identity synchronization preserves #{status} lifecycle status" do
      identity = verified_identity_fixture()
      {:ok, user} = Accounts.sync_verified_identity(identity, now: @now)
      {:ok, user} = Accounts.set_user_status(user, unquote(status), now: @now)

      assert {:ok, synced} =
               Accounts.sync_verified_identity(%{identity | first_name: "Updated"}, now: @now)

      assert synced.id == user.id
      assert synced.status == unquote(status)
    end
  end

  test "database independently enforces issuer/subject uniqueness and account status" do
    user = user_fixture(%{}, now: @now)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               """
               INSERT INTO users (keycloak_issuer, keycloak_subject, email, last_authenticated_at,
                 profile_synced_at, inserted_at, updated_at)
               SELECT keycloak_issuer, keycloak_subject, email, last_authenticated_at,
                 profile_synced_at, inserted_at, updated_at FROM users WHERE id = $1
               """,
               [user.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE users SET status = 'owner' WHERE id = $1", [user.id],
               mode: :savepoint
             )

    assert {:error, changeset} = Accounts.set_user_status(user, :owner, now: @now)
    assert errors_on(changeset).status
  end

  test "identity bounds and clocks are validated without accepting arbitrary HTTP-shaped data" do
    for attrs <- [
          %{issuer: " "},
          %{subject: ""},
          %{subject: String.duplicate("x", 1025)},
          %{email: ""}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               attrs |> verified_identity_fixture() |> Accounts.sync_verified_identity(now: @now)
    end

    assert {:error, :invalid_options} =
             Accounts.sync_verified_identity(verified_identity_fixture(), now: "today")

    assert {:ok, user} =
             Accounts.sync_verified_identity(verified_identity_fixture(),
               now: ~U[2026-10-28 12:00:00.999999Z]
             )

    assert user.inserted_at == @now
  end

  test "booking customer email does not create or link a Magnum user" do
    price = SchedulerApi.CatalogFixtures.service_price_fixture()
    attrs = SchedulerApi.AppointmentsFixtures.booking_attrs(price)
    assert {:ok, appointment} = SchedulerApi.Appointments.create_appointment(attrs)
    assert appointment.customer_email == attrs.customer_email
    assert Repo.aggregate(User, :count) == 0
    refute :user_id in SchedulerApi.Appointments.Appointment.__schema__(:fields)
  end

  test "users have only identity/profile/lifecycle fields, no credential or authorization storage" do
    assert MapSet.new(User.__schema__(:fields)) ==
             MapSet.new([
               :id,
               :keycloak_issuer,
               :keycloak_subject,
               :email,
               :email_verified,
               :first_name,
               :last_name,
               :status,
               :last_authenticated_at,
               :profile_synced_at,
               :inserted_at,
               :updated_at
             ])

    refute :business in User.__schema__(:associations)
    refute :shop in User.__schema__(:associations)
    refute function_exported?(VerifiedIdentity, :from_params, 1)
  end
end
