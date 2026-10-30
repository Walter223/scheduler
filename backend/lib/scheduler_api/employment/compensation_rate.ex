defmodule SchedulerApi.Employment.CompensationRate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "compensation_rates" do
    belongs_to :business, SchedulerApi.Organizations.Business
    belongs_to :employment, SchedulerApi.Employment.EmploymentRecord
    field :pay_basis, Ecto.Enum, values: [:hourly, :annual_salary]
    field :currency, :string, default: "USD"
    field :amount, :decimal, redact: true
    field :effective_from, :date
    field :effective_until, :date
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields [:amount, :pay_basis, :currency, :effective_from, :effective_until]
  @doc false
  def creation_changeset(rate, attrs) do
    {params, valid_keys?} = params(attrs)
    input = params["amount"]

    exact_input? =
      is_integer(input) or match?(%Decimal{}, input) or
        (is_binary(input) and byte_size(input) <= 64)

    params = if exact_input?, do: params, else: Map.delete(params, "amount")

    rate
    |> cast(params, @fields)
    |> validate_required([
      :business_id,
      :employment_id,
      :pay_basis,
      :currency,
      :amount,
      :effective_from
    ])
    |> validate_inclusion(:currency, ["USD"])
    |> validate_change(:amount, fn :amount, amount ->
      case amount do
        %Decimal{coef: coefficient, exp: exponent}
        when is_integer(coefficient) and exponent in -2..12 ->
          if Decimal.compare(amount, 0) == :gt and Decimal.compare(amount, "1000000000000") == :lt,
            do: [],
            else: [amount: "must be a positive USD amount below one trillion"]

        _ ->
          [amount: "must be finite with at most two decimal places"]
      end
    end)
    |> then(fn cs -> if valid_keys?, do: cs, else: add_error(cs, :base, "unsupported fields") end)
    |> then(fn cs ->
      if exact_input?,
        do: cs,
        else: add_error(cs, :amount, "must be an exact decimal string or integer")
    end)
    |> add_constraints()
  end

  defp params(attrs) when is_map(attrs) do
    valid? =
      Enum.all?(
        Map.keys(attrs),
        &(&1 in @fields or &1 in Enum.map(@fields, fn field -> Atom.to_string(field) end))
      )

    valid? =
      valid? and
        Enum.all?(@fields, fn field ->
          not (Map.has_key?(attrs, field) and Map.has_key?(attrs, Atom.to_string(field)))
        end)

    params =
      for field <- @fields, reduce: %{} do
        acc ->
          key = Atom.to_string(field)

          cond do
            Map.has_key?(attrs, field) -> Map.put(acc, key, attrs[field])
            Map.has_key?(attrs, key) -> Map.put(acc, key, attrs[key])
            true -> acc
          end
      end

    {params, valid?}
  end

  defp params(_), do: {%{}, false}

  @doc false
  def close_changeset(rate, date), do: rate |> change(effective_until: date) |> add_constraints()

  defp add_constraints(cs) do
    cs
    |> foreign_key_constraint(:employment_id, name: :compensation_rates_employment_business_fkey)
    |> exclusion_constraint(:effective_from, name: :compensation_rates_no_overlap)
    |> check_constraint(:amount, name: :compensation_rates_money_valid)
    |> check_constraint(:effective_until, name: :compensation_rates_dates_valid)
    |> check_constraint(:effective_from, name: :compensation_rates_employment_valid)
    |> check_constraint(:amount, name: :compensation_rates_immutable)
  end
end
