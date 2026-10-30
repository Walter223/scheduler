defmodule SchedulerApi.WorkShiftFixtures do
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Employment, Repo}
  alias SchedulerApi.Organizations.Business

  def work_shift_fixture do
    employment = employment_fixture()
    business = Repo.get!(Business, employment.business_id)
    shop = shop_fixture(%{business_id: business.id})
    {:ok, assignment} = Employment.assign_shop(employment, shop, %{starts_on: ~D[2026-01-01]})
    owner = active_user_fixture()
    {membership, grant} = grant_fixture(owner, shop, :business_owner)
    {:ok, session, credential} = Accounts.create_session(owner)

    %{
      employment: employment,
      business: business,
      shop: shop,
      assignment: assignment,
      owner: owner,
      membership: membership,
      grant: grant,
      session: session,
      credential: credential
    }
  end
end
