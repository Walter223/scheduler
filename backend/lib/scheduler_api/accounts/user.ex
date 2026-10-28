defmodule SchedulerApi.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset
  alias SchedulerApi.Accounts.VerifiedIdentity

  schema "users" do
    field :keycloak_issuer, :string
    field :keycloak_subject, :string
    field :email, :string
    field :email_verified, :boolean, default: false
    field :first_name, :string
    field :last_name, :string

    field :status, Ecto.Enum,
      values: [:pending, :active, :suspended, :deactivated],
      default: :pending

    field :last_authenticated_at, :utc_datetime
    field :profile_synced_at, :utc_datetime
    has_many :web_sessions, SchedulerApi.Accounts.WebSession
    timestamps(type: :utc_datetime)
  end

  @doc false
  def identity_changeset(%VerifiedIdentity{} = identity, now, authenticated_at) do
    # Identity is assigned only from the trusted type, never normalized or
    # inferred from email. The conflict update never replaces this key/status.
    %__MODULE__{keycloak_issuer: identity.issuer, keycloak_subject: identity.subject}
    |> change()
    |> cast(
      Map.take(identity, [:email, :email_verified, :first_name, :last_name]),
      [:email, :email_verified, :first_name, :last_name]
    )
    |> put_change(:last_authenticated_at, authenticated_at)
    |> put_change(:profile_synced_at, now)
    |> put_change(:inserted_at, now)
    |> put_change(:updated_at, now)
    |> validate_required([:keycloak_issuer, :keycloak_subject, :email, :email_verified])
    |> validate_length(:email, max: 320)
    |> validate_length(:first_name, max: 255)
    |> validate_length(:last_name, max: 255)
    |> validate_identity_key(:keycloak_issuer)
    |> validate_identity_key(:keycloak_subject)
    |> unique_constraint([:keycloak_issuer, :keycloak_subject])
    |> check_constraint(:email, name: :users_email_not_blank)
  end

  @doc false
  def status_changeset(user, status) do
    user
    |> cast(%{status: status}, [:status])
    |> validate_required([:status])
    |> check_constraint(:status, name: :users_status_valid)
  end

  defp validate_identity_key(changeset, field) do
    value = get_field(changeset, field)

    changeset =
      if is_binary(value) and String.valid?(value) and byte_size(value) <= 1024 and
           String.trim(value) != "",
         do: changeset,
         else: add_error(changeset, field, "must be nonblank text of at most 1024 bytes")

    check_constraint(changeset, field, name: "users_#{field}_valid")
  end
end
