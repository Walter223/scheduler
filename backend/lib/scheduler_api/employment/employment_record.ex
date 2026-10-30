defmodule SchedulerApi.Employment.EmploymentRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @classifications [:detailer, :shop_manager, :business_manager, :business_owner]
  def classifications, do: @classifications

  schema "employments" do
    belongs_to :employee, __MODULE__, define_field: false
    field :employee_id, :id, read_after_writes: true
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :user, SchedulerApi.Accounts.User
    field :first_name, :string
    field :last_name, :string
    # Business-specific contact data; never fall back to identity-provider profiles.
    field :phone, :string, redact: true
    field :email, :string, redact: true
    field :home_address, :string, redact: true
    field :classification, Ecto.Enum, values: @classifications
    field :status, Ecto.Enum, values: [:active, :ended], default: :active
    field :starts_on, :date
    field :ends_on, :date

    has_many :shop_assignments, SchedulerApi.Employment.ShopAssignment,
      foreign_key: :employment_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def creation_changeset(record, attrs) do
    record
    |> cast(attrs, [:first_name, :last_name, :classification, :starts_on])
    |> update_change(:first_name, &trim_name/1)
    |> update_change(:last_name, &trim_name/1)
    |> validate_required([:business_id, :first_name, :last_name, :classification, :starts_on])
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
    |> add_constraints()
  end

  @doc false
  def contact_changeset(record_or_changeset, attrs) do
    record_or_changeset
    |> cast(attrs, [:first_name, :last_name, :phone, :email, :home_address])
    |> then(fn cs ->
      Enum.reduce([:first_name, :last_name, :phone, :email, :home_address], cs, fn field, acc ->
        update_change(acc, field, fn value ->
          if is_binary(value),
            do:
              (case String.trim(value) do
                 "" -> nil
                 trimmed -> trimmed
               end),
            else: value
        end)
      end)
    end)
    |> validate_required([:first_name, :last_name])
    |> validate_length(:first_name, max: 100)
    |> validate_length(:last_name, max: 100)
    |> validate_length(:phone, max: 32)
    |> validate_length(:email, max: 320)
    |> validate_length(:home_address, max: 1000)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  @doc false
  def end_changeset(record, date) do
    record |> change(status: :ended, ends_on: date) |> add_constraints()
  end

  defp trim_name(value) when is_binary(value), do: String.trim(value)
  defp trim_name(value), do: value

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:business_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:user_id, name: :employments_user_business_fkey)
    |> unique_constraint(:user_id, name: :employments_business_id_user_id_index)
    |> check_constraint(:user_id, name: :employments_link_eligible)
    |> check_constraint(:classification, name: :employments_classification_valid)
    |> check_constraint(:first_name, name: :employments_names_valid)
    |> check_constraint(:ends_on, name: :employments_lifecycle)
    |> check_constraint(:ends_on, name: :employments_assignments_closed)
    |> check_constraint(:classification, name: :employments_immutable)
  end
end
