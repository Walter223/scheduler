defmodule SchedulerApi.Employment.HTTPWrites do
  @moduledoc "HTTP field/identifier adapter only. All mutations use authorized HR workflows."
  import Ecto.Query
  alias SchedulerApi.{Authorization, Repo}
  alias SchedulerApi.Organizations.Business
  alias SchedulerApi.Employment.{HR, EmploymentRecord, ShopAssignment}
  @contacts ~w(first_name last_name phone email home_address)
  def run(action, credential, user, path, body, query) do
    with {:ok, business_id} <- id(path["business_id"]),
         :ok <- Authorization.authorize(user, :employment_manage, %Business{id: business_id}),
         :ok <- payload(body, fields(action)),
         true <- query == %{} do
      if action == :create do
        normalize(
          HR.create_employment(credential, %Business{id: business_id}, body),
          :create,
          nil
        )
      else
        with {:ok, employee_id} <- id(path["employee_id"]),
             {:ok, period_id} <- id(path["period_id"]),
             %EmploymentRecord{} = period <-
               Repo.one(
                 from e in EmploymentRecord,
                   where:
                     e.id == ^period_id and e.employee_id == ^employee_id and
                       e.business_id == ^business_id
               ) do
          normalize(dispatch(action, credential, period, path, body), action, period)
        else
          nil -> {:error, :forbidden}
          error -> error
        end
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp normalize({:ok, %{employment: value} = result}, :terminate, e),
    do: {:ok, %{result | employment: identifiers(value, e)}}

  defp normalize({:ok, value}, action, e) when action in [:assign_shop, :end_shop],
    do:
      {:ok,
       value
       |> Map.drop([:id, :employment_id])
       |> Map.merge(%{assignment_id: value.id, period_id: e.id, employee_id: e.employee_id})}

  defp normalize({:ok, value}, _, e), do: {:ok, identifiers(value, e)}
  defp normalize(error, _, _), do: error

  defp identifiers(value, e),
    do:
      value
      |> Map.drop([:id, :employee_id])
      |> Map.merge(%{
        period_id: value.id,
        employee_id: Map.get(value, :employee_id) || (e && e.employee_id) || value.id
      })

  defp dispatch(:contact, c, e, _, b), do: HR.update_contact(c, e, b)

  defp dispatch(:classification, c, e, _, b),
    do: HR.change_classification(c, e, Map.get(b, "classification"))

  defp dispatch(:terminate, c, e, _, _), do: HR.terminate_employment(c, e)
  defp dispatch(:rehire, c, e, _, b), do: HR.rehire_employment(c, e, Map.get(b, "starts_on"))

  defp dispatch(:assign_shop, c, e, _, b) do
    with {:ok, id} <- id(b["shop_id"]),
         do:
           HR.assign_shop(
             c,
             e,
             %SchedulerApi.Organizations.Shop{id: id},
             Map.take(b, ["starts_on"])
           )
  end

  defp dispatch(:end_shop, c, e, path, b) do
    with {:ok, id} <- id(path["assignment_id"]),
         %ShopAssignment{} = a <-
           Repo.one(
             from a in ShopAssignment,
               where: a.id == ^id and a.employment_id == ^e.id and a.business_id == ^e.business_id
           ) do
      HR.end_shop_assignment(c, a, Map.get(b, "ends_on"))
    else
      nil -> {:error, :forbidden}
      error -> error
    end
  end

  defp fields(:create), do: @contacts ++ ~w(classification starts_on)
  defp fields(:contact), do: @contacts
  defp fields(:classification), do: ~w(classification)
  defp fields(:assign_shop), do: ~w(shop_id starts_on)
  defp fields(:end_shop), do: ~w(ends_on)
  defp fields(:rehire), do: ~w(starts_on)
  defp fields(:terminate), do: []

  defp payload(body, fields) when is_map(body) do
    if Enum.all?(Map.keys(body), &(&1 in fields)), do: :ok, else: {:error, :invalid_input}
  end

  defp payload(_, _), do: {:error, :invalid_input}

  defp id(v) when is_integer(v) and v > 0 and v <= 9_223_372_036_854_775_807, do: {:ok, v}

  defp id(v) when is_binary(v) and byte_size(v) in 1..19 do
    case Integer.parse(v) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> {:error, :invalid_input}
    end
  end

  defp id(_), do: {:error, :invalid_input}
end
