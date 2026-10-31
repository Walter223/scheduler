defmodule SchedulerApiWeb.DashboardControllerTest do
  use SchedulerApiWeb.ConnCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.AccountsFixtures
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()

  defp request(c, user, query \\ "") do
    {_, token} = session_fixture(user)

    build_conn()
    |> put_req_cookie(BrowserSession.session_name(), token)
    |> get("/api/admin/businesses/#{c.business.id}/dashboard" <> query)
  end

  test "live authenticated scope, empty schedules, no-store and strict selectors", c do
    path = "/api/admin/businesses/#{c.business.id}/dashboard"
    assert build_conn() |> get(path) |> json_response(401)
    conn = request(c, c.owner)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert json_response(conn, 200)["data"]["metrics"]["appointments"] == 0

    for q <- ["?business_id=1", "?shop_id=bad", "?shop_id=0"],
        do: assert(json_response(request(c, c.owner, q), 422))

    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    assert json_response(request(c, manager), 403) == %{"error" => "forbidden"}
    {_, token} = session_fixture(c.owner)
    {:ok, _} = SchedulerApi.Organizations.Memberships.revoke(c.membership)

    assert build_conn()
           |> put_req_cookie(BrowserSession.session_name(), token)
           |> get(path)
           |> json_response(403)

    Accounts.set_user_status(c.owner, :suspended)

    assert build_conn()
           |> put_req_cookie(BrowserSession.session_name(), token)
           |> get(path)
           |> json_response(401)

    assert Repo.get!(SchedulerApi.Organizations.BusinessMembership, c.membership.id).status ==
             :revoked
  end
end
