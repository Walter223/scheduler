defmodule SchedulerApi.CompensationFixtures do
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Organizations.Business

  def compensation_fixture do
    employment = employment_fixture()
    business = Repo.get!(Business, employment.business_id)
    shop = shop_fixture(%{business_id: business.id})
    owner = active_user_fixture()
    {membership, grant} = grant_fixture(owner, shop, :business_owner)
    {:ok, session, credential} = Accounts.create_session(owner)

    %{
      employment: employment,
      business: business,
      shop: shop,
      owner: owner,
      membership: membership,
      grant: grant,
      session: session,
      credential: credential
    }
  end
end
