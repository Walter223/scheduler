defmodule SchedulerApiWeb.AdminContextControllerTest do
  use SchedulerApiWeb.ConnCase, async: true
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.Repo
  alias SchedulerApi.Organizations.Business
  alias SchedulerApiWeb.BrowserSession

  defp contexts(user) do
    {_, token} = session_fixture(user)

    build_conn()
    |> put_req_cookie(BrowserSession.session_name(), token)
    |> get("/api/admin/context")
    |> json_response(200)
  end

  test "anonymous denial and employees never gain management navigation" do
    assert build_conn() |> get("/api/admin/context") |> json_response(401)
    user = active_user_fixture()
    grant_fixture(user, shop_fixture(), :employee)
    assert contexts(user) == %{"businesses" => []}
  end

  test "Owner inheritance and separate Manager business scopes" do
    user = active_user_fixture()
    a = shop_fixture()
    {m, _} = grant_fixture(user, a, :business_owner)
    b = Repo.insert!(%Business{name: "Separate", slug: "separate-context"})
    grant_fixture(user, shop_fixture(%{business_id: b.id}), :business_manager)
    data = contexts(user)["businesses"]
    first = Enum.find(data, &(&1["id"] == a.business_id))
    other = Enum.find(data, &(&1["id"] == b.id))
    assert "settings" in first["capabilities"] and "employees" in first["capabilities"]
    assert "appointments" in first["all_shops"]
    refute "settings" in other["capabilities"]
    assert other["shops"] == []
    {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(m)
    assert Enum.map(contexts(user)["businesses"], & &1["id"]) == [b.id]
  end

  test "Shop Managers see only assigned active shops" do
    user = active_user_fixture()
    shop = shop_fixture()
    other = shop_fixture()
    grant_fixture(user, shop, :shop_manager)
    data = hd(contexts(user)["businesses"])
    assert "roster" in hd(data["shops"])["capabilities"]
    refute "employees" in data["capabilities"]
    assert data["all_shops"] == []
    assert Enum.map(data["shops"], & &1["id"]) == [shop.id]
    refute Enum.any?(data["shops"], &(&1["id"] == other.id))
  end
end
