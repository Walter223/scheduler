defmodule SchedulerApi.Employment.WorkShift do
  use Ecto.Schema
  import Ecto.Changeset

  schema "work_shifts" do
    belongs_to :assignment, SchedulerApi.Employment.ShopAssignment
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :shop, SchedulerApi.Organizations.Shop
    belongs_to :supersedes, __MODULE__
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :timezone, :string
    field :status, Ecto.Enum, values: [:active, :cancelled, :superseded], default: :active
    field :closed_at, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Only explicit instants are accepted; naive local values need WorkSchedules.local_to_utc/3."
  def instant(%DateTime{microsecond: {0, _}} = value),
    do: {:ok, value |> DateTime.to_unix(:second) |> DateTime.from_unix!(:second)}

  def instant(value) when is_binary(value) and byte_size(value) <= 64 do
    with {:ok, datetime, _} <- DateTime.from_iso8601(value), do: instant(datetime)
  end

  def instant(_), do: {:error, :invalid_input}

  @doc false
  def creation_changeset(shift, attrs) do
    {params, valid?} = normalize(attrs)

    shift
    |> cast(params, [:starts_at, :ends_at])
    |> validate_required([
      :assignment_id,
      :employment_id,
      :business_id,
      :shop_id,
      :timezone,
      :starts_at,
      :ends_at
    ])
    |> then(fn cs ->
      first = get_field(cs, :starts_at)
      last = get_field(cs, :ends_at)

      if first && last && DateTime.compare(first, last) != :lt,
        do: add_error(cs, :ends_at, "must be after starts_at"),
        else: cs
    end)
    |> then(fn cs ->
      if valid?,
        do: cs,
        else: add_error(cs, :base, "explicit whole-second instants and allowed fields required")
    end)
    |> add_constraints()
  end

  defp normalize(attrs) when is_map(attrs) do
    valid? =
      Enum.all?(Map.keys(attrs), &(&1 in [:starts_at, :ends_at, "starts_at", "ends_at"])) and
        Enum.all?(
          [:starts_at, :ends_at],
          &(not (Map.has_key?(attrs, &1) and Map.has_key?(attrs, Atom.to_string(&1))))
        )

    Enum.reduce([:starts_at, :ends_at], {%{}, valid?}, fn field, {params, valid} ->
      case instant(Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))) do
        {:ok, value} -> {Map.put(params, field, value), valid}
        _ -> {params, false}
      end
    end)
  end

  defp normalize(_), do: {%{}, false}

  @doc false
  def close_changeset(shift, status, now),
    do: shift |> change(status: status, closed_at: now) |> add_constraints()

  defp add_constraints(cs) do
    cs
    |> foreign_key_constraint(:assignment_id, name: :work_shifts_assignment_fkey)
    |> foreign_key_constraint(:supersedes_id, name: :work_shifts_supersedes_fkey)
    |> unique_constraint(:supersedes_id)
    |> exclusion_constraint(:starts_at, name: :work_shifts_no_active_overlap)
    |> check_constraint(:ends_at, name: :work_shifts_period_valid)
    |> check_constraint(:status, name: :work_shifts_lifecycle)
    |> check_constraint(:assignment_id, name: :work_shifts_assignment_eligible)
    |> check_constraint(:timezone, name: :work_shifts_timezone_valid)
    |> check_constraint(:status, name: :work_shifts_immutable)
    |> check_constraint(:supersedes_id, name: :work_shifts_replacement_valid)
  end
end
