defmodule SchedulerApi.OwnerTerminationTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.CompensationFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  alias SchedulerApi.{Accounts, Authorization, Repo}
  alias SchedulerApi.Employment.{HR, OffboardingAudit}
  alias SchedulerApi.Authorization.RoleManagement

  setup do
    c = compensation_fixture()
    manager = active_user_fixture()
    {member, grant} = grant_fixture(manager, c.shop, :business_manager)
    {:ok, _, token} = Accounts.create_session(manager)

    Map.merge(c, %{
      manager: manager,
      manager_member: member,
      manager_grant: grant,
      manager_token: token
    })
  end

  test "unlinked Owner classification is protected without any role grant", c do
    e = employment_fixture(%{classification: :business_owner}, business: c.business)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager_token, e)
    assert {:error, :forbidden} = Authorization.authorize(c.manager, :employment_terminate, e)
    assert Repo.reload!(e).status == :active
    assert Repo.aggregate(OffboardingAudit, :count) == 0
  end

  test "linked Owner classification is protected with only Employee and revoked Owner grants",
       c do
    user = active_user_fixture()
    {member, _} = grant_fixture(user, c.shop, :employee)
    e = employment_fixture(%{classification: :business_owner}, business: c.business, user: user)

    assert {:error, :forbidden} =
             HR.terminate_employment(c.manager_token, %{e | classification: :detailer})

    assert {:error, :forbidden} = RoleManagement.revoke_employment_access(c.manager_token, e)
    {_, owner} = grant_fixture(user, c.shop, :business_owner)
    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, owner)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager_token, e)
    assert Repo.reload!(member).status == :active
  end

  test "past Owner classification cannot be downgraded into HR termination eligibility", c do
    e = employment_fixture(%{classification: :business_owner}, business: c.business)
    {:ok, _} = HR.change_classification(c.credential, e, :detailer)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager_token, Repo.reload!(e))

    assert {:error, :forbidden} =
             Authorization.authorize(c.manager, :employment_terminate, %{
               e
               | classification: :detailer
             })

    # Explicit Owner-managed transition still works; no privilege is inferred
    # from the target's classification or from the caller's submitted struct.
    assert {:ok, _} = HR.terminate_employment(c.credential, e)
  end

  test "historical Owner grant protects a Detailer-classified target after revocation", c do
    user = active_user_fixture()
    grant_fixture(user, c.shop, :employee)
    {_, owner} = grant_fixture(user, c.shop, :business_owner)
    e = employment_fixture(%{}, business: c.business, user: user)
    assert {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, owner)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager_token, e)
    assert Repo.reload!(e).status == :active
  end

  test "Owner can terminate HR employment without affecting the same person's other-business access",
       c do
    target = active_user_fixture()
    grant_fixture(target, c.shop, :business_manager)

    e =
      employment_fixture(%{classification: :business_manager}, business: c.business, user: target)

    foreign = compensation_fixture()
    {other_membership, _} = grant_fixture(target, foreign.shop, :business_owner)
    {:ok, _, token} = Accounts.create_session(target)
    assert {:ok, _} = HR.terminate_employment(c.credential, e)
    assert Repo.reload!(other_membership).status == :active
    assert :ok = Authorization.authorize(target, :access_manage, foreign.business)

    assert {:ok, _} =
             Accounts.get_session_by_token(SchedulerApi.Accounts.SessionCredential.reveal(token))
  end

  test "non-Owner management history is not mistaken for protected ownership", c do
    e = employment_fixture(%{classification: :shop_manager}, business: c.business)
    {:ok, _} = HR.change_classification(c.credential, e, :business_manager)
    {:ok, _} = HR.change_classification(c.credential, e, :detailer)
    assert {:ok, _} = HR.terminate_employment(c.manager_token, e)
  end

  test "stale Owner roles, suspended actors and foreign scopes confer no termination permission",
       c do
    e = employment_fixture(%{classification: :business_owner}, business: c.business)
    backup = active_user_fixture()
    grant_fixture(backup, c.shop, :business_owner)
    {:ok, _} = RoleManagement.revoke_role(c.credential, c.business, c.grant)
    assert {:error, :forbidden} = HR.terminate_employment(c.credential, e)
    assert {:error, :forbidden} = Authorization.authorize(c.owner, :employment_terminate, e)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager, e)

    assert {:error, :forbidden} =
             HR.terminate_employment(c.manager_token, %SchedulerApi.Employment.EmploymentRecord{
               id: -1
             })

    {:ok, _} = Accounts.set_user_status(c.manager, :suspended)
    assert {:error, :forbidden} = HR.terminate_employment(c.manager_token, e)
  end
end
