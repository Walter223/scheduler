defmodule SchedulerApi.AdminAccessFixtures do
  @moduledoc "Isolated test access only; never production grants or HTTP bypasses."
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.Organizations.{BusinessMembership, RoleAssignment}

  def grant_fixture(user, shop, role) do
    membership =
      Repo.get_by(BusinessMembership, user_id: user.id, business_id: shop.business_id) ||
        Repo.insert!(%BusinessMembership{user_id: user.id, business_id: shop.business_id})

    assignment =
      Repo.insert!(%RoleAssignment{
        membership_id: membership.id,
        business_id: shop.business_id,
        role: role,
        shop_id: if(role in [:shop_manager, :employee], do: shop.id)
      })

    {membership, assignment}
  end

  def session_fixture(user, opts \\ []) do
    {:ok, session, credential} = Accounts.create_session(user, opts)
    {session, SessionCredential.reveal(credential)}
  end
end
