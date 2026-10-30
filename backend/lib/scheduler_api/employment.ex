defmodule SchedulerApi.Employment do
  @moduledoc """
  Internal employment persistence, NOT an HR authorization or account-linking API.
  Callers must eventually enforce HR permissions separately. No role, membership,
  account activation or scheduling effects. Structs are references; reload ownership.
  """
  import Ecto.Query
  alias SchedulerApi.Repo
  alias SchedulerApi.Accounts.User
  alias SchedulerApi.Organizations.{Business, Shop}
  alias SchedulerApi.Employment.{EmploymentRecord, ShopAssignment}

  @doc "Creates independent employment; optional :user must already be eligible in this business."
  def create_employment(%Business{id: id}, attrs, opts \\ []) do
    Repo.transaction(fn ->
      business = active_business!(id)

      user_id =
        case Keyword.get(opts, :user) do
          nil -> nil
          %User{id: user_id} when is_integer(user_id) -> user_id
          _ -> Repo.rollback(:invalid_user)
        end

      %EmploymentRecord{business_id: business.id, user_id: user_id}
      |> EmploymentRecord.creation_changeset(attrs)
      |> insert!()
    end)
  end

  @doc "Tenant-scoped internal retrieval; not an authorization decision."
  def get_employment(%Business{id: business_id}, id) do
    Repo.one(from e in EmploymentRecord, where: e.id == ^id and e.business_id == ^business_id)
  end

  def list_employments(%Business{id: business_id}) do
    Repo.all(from e in EmploymentRecord, where: e.business_id == ^business_id, order_by: e.id)
  end

  def assign_shop(%EmploymentRecord{id: id}, %Shop{id: shop_id}, attrs) do
    Repo.transaction(fn ->
      employment = lock_employment!(id)
      active_business!(employment.business_id)
      if employment.status != :active, do: Repo.rollback(:employment_ended)
      shop = Repo.one(from s in Shop, where: s.id == ^shop_id, lock: "FOR SHARE")

      cond do
        is_nil(shop) -> Repo.rollback(:shop_not_found)
        shop.business_id != employment.business_id -> Repo.rollback(:wrong_business)
        shop.status != :active -> Repo.rollback(:inactive_shop)
        true -> :ok
      end

      %ShopAssignment{
        employment_id: employment.id,
        business_id: employment.business_id,
        shop_id: shop.id
      }
      |> ShopAssignment.creation_changeset(attrs)
      |> insert!()
    end)
  end

  def list_shop_assignments(%Business{id: business_id}, %EmploymentRecord{id: id}) do
    Repo.all(
      from a in ShopAssignment,
        where: a.business_id == ^business_id and a.employment_id == ^id,
        order_by: a.id
    )
  end

  @doc "Ends all active shop assignments and employment atomically; ended history is terminal."
  def end_employment(%EmploymentRecord{id: id}, %Date{} = date) do
    Repo.transaction(fn ->
      employment = lock_employment!(id)

      if employment.status == :ended do
        if employment.ends_on != date, do: Repo.rollback(:already_ended)
        employment
      else
        assignments =
          Repo.all(from a in ShopAssignment, where: a.employment_id == ^id, order_by: a.id)

        if Date.compare(date, employment.starts_on) == :lt or
             Enum.any?(assignments, fn a ->
               Date.compare(date, a.ends_on || a.starts_on) == :lt
             end),
           do: Repo.rollback(:invalid_end_date)

        for a <- assignments, a.status == :active do
          a |> ShopAssignment.end_changeset(date) |> update!()
        end

        employment |> EmploymentRecord.end_changeset(date) |> update!()
      end
    end)
  end

  def end_employment(_, _), do: {:error, :invalid_date}

  def end_shop_assignment(%ShopAssignment{id: id}, %Date{} = date) do
    Repo.transaction(fn ->
      reference = Repo.get(ShopAssignment, id) || Repo.rollback(:assignment_not_found)
      # Always parent before child, matching assignment creation and termination.
      lock_employment!(reference.employment_id)
      assignment = Repo.get!(ShopAssignment, id)

      if assignment.status == :ended do
        if assignment.ends_on != date, do: Repo.rollback(:already_ended)
        assignment
      else
        if Date.compare(date, assignment.starts_on) == :lt, do: Repo.rollback(:invalid_end_date)
        assignment |> ShopAssignment.end_changeset(date) |> update!()
      end
    end)
  end

  def end_shop_assignment(_, _), do: {:error, :invalid_date}

  defp active_business!(id) do
    business =
      Repo.one(from b in Business, where: b.id == ^id, lock: "FOR SHARE") ||
        Repo.rollback(:business_not_found)

    if business.status != :active, do: Repo.rollback(:inactive_business)
    business
  end

  defp lock_employment!(id),
    do:
      Repo.one(from e in EmploymentRecord, where: e.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:employment_not_found)

  defp insert!(changeset), do: persist(Repo.insert(changeset))
  defp update!(changeset), do: persist(Repo.update(changeset))
  defp persist({:ok, value}), do: value
  defp persist({:error, changeset}), do: Repo.rollback(changeset)
end
