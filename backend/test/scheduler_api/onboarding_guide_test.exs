defmodule SchedulerApi.OnboardingGuideTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.BusinessOnboarding, as: W
  alias SchedulerApi.Accounts.SessionCredential

  setup do
    shop = shop_fixture()
    u = active_user_fixture()
    grant_fixture(u, shop, :business_owner)
    {_, raw} = session_fixture(u)
    token = %SessionCredential{value: raw}
    {:ok, d} = W.start(token, shop.business_id)
    %{shop: shop, u: u, token: token, d: d}
  end

  defp command(rev, action, proposal \\ nil),
    do: %{
      "revision" => rev,
      "request_id" => Ecto.UUID.generate(),
      "action" => action,
      "topic" => "branding",
      "proposal" => proposal
    }

  test "proposals require explicit approval, retry and resume without live changes", c do
    attrs = command(0, "propose", %{"branding" => %{"display_name" => "Fictional"}})
    assert {:ok, g} = W.guide(c.token, c.shop.business_id, attrs)
    assert {:ok, ^g} = W.guide(c.token, c.shop.business_id, attrs)
    assert {:ok, ^g} = W.guide(c.token, c.shop.business_id)
    assert {:ok, d} = W.get(c.token, c.shop.business_id)
    assert d["proposal"]["branding"] == %{}
    approval = command(g["revision"], "approve")
    assert {:ok, a} = W.guide(c.token, c.shop.business_id, approval)
    assert {:ok, ^a} = W.guide(c.token, c.shop.business_id, approval)
    assert {:ok, saved} = W.get(c.token, c.shop.business_id)
    assert saved["proposal"]["branding"]["display_name"] == "Fictional"
    assert saved["readiness"]["published"] == false
    assert Repo.get!(SchedulerApi.Organizations.Business, c.shop.business_id).name != "Fictional"
  end

  test "invalid structured input, stale revisions and manual editor collisions fail closed", c do
    assert {:error, :invalid_input} =
             W.guide(
               c.token,
               c.shop.business_id,
               command(0, "propose", %{"password" => "forbidden"})
             )

    assert {:ok, g} =
             W.guide(c.token, c.shop.business_id, command(0, "propose", %{"branding" => %{}}))

    assert {:error, :revision_conflict} =
             W.guide(c.token, c.shop.business_id, command(0, "approve"))

    assert {:ok, _} =
             W.update(c.token, c.shop.business_id, %{
               "revision" => g["revision"],
               "request_id" => Ecto.UUID.generate(),
               "state" => c.d["state"],
               "proposal" => c.d["proposal"]
             })

    assert {:error, :revision_conflict} =
             W.guide(c.token, c.shop.business_id, command(g["revision"], "approve"))
  end

  test "Owner private history and cross-tenant/session denial", c do
    other = active_user_fixture()
    grant_fixture(other, c.shop, :business_owner)
    {_, raw} = session_fixture(other)

    assert {:ok, _} =
             W.guide(c.token, c.shop.business_id, command(0, "propose", %{"branding" => %{}}))

    assert {:ok, g} = W.guide(%SessionCredential{value: raw}, c.shop.business_id)
    assert g["history"] == []

    for role <- [:business_manager, :shop_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      {_, token} = session_fixture(user)
      assert {:error, :forbidden} = W.guide(%SessionCredential{value: token}, c.shop.business_id)
    end

    draft = Repo.get_by!(SchedulerApi.BusinessOnboarding.Draft, business_id: c.shop.business_id)
    key = Integer.to_string(c.u.id)
    state = put_in(draft.guide_state, [key, "expires_at"], 0)
    Repo.update!(Ecto.Changeset.change(draft, guide_state: state))
    assert {:ok, expired} = W.guide(c.token, c.shop.business_id)
    refute Map.has_key?(expired, "pending")
    assert expired["history"] == []

    assert {:error, :revision_conflict} =
             W.guide(c.token, c.shop.business_id, command(expired["revision"], "approve"))

    foreign = other_business_price_fixture().shop
    assert {:error, :forbidden} = W.guide(c.token, foreign.business_id)
    {:ok, _} = SchedulerApi.Accounts.set_user_status(c.u, :suspended)
    assert {:error, :invalid_session} = W.guide(c.token, c.shop.business_id)
  end

  test "audit failure rolls back pending state and receipts", c do
    Repo.query!(
      "ALTER TABLE business_onboarding_events ADD CONSTRAINT guide_audit_failure CHECK (revision=0) NOT VALID"
    )

    assert {:error, :operation_unavailable} =
             W.guide(c.token, c.shop.business_id, command(0, "propose", %{"branding" => %{}}))

    assert {:ok, g} = W.guide(c.token, c.shop.business_id)
    assert g["history"] == []
    assert g["revision"] == 0
  end
end
