defmodule SchedulerApiWeb.BusinessOnboardingControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.Accounts
  alias SchedulerApiWeb.BrowserSession

  setup do
    shop = shop_fixture()
    owner = active_user_fixture()
    grant_fixture(owner, shop, :business_owner)
    {session, token} = session_fixture(owner)

    %{
      shop: shop,
      owner: owner,
      session: session,
      token: token,
      path: "/api/admin/businesses/#{shop.business_id}/onboarding"
    }
  end

  defp auth(token), do: put_req_cookie(build_conn(), BrowserSession.session_name(), token)

  defp write(c, method, body, opts \\ []) do
    csrf = auth(c.token) |> get("/api/me") |> json_response(200) |> Map.get("csrf_token")

    conn =
      auth(c.token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", Keyword.get(opts, :origin, "http://localhost:5173"))

    conn =
      if Keyword.get(opts, :csrf, true) && csrf,
        do: put_req_header(conn, "x-csrf-token", csrf),
        else: conn

    if method == :post,
      do: post(conn, c.path, Jason.encode!(body)),
      else: put(conn, c.path, Jason.encode!(body))
  end

  test "private authenticated Owner API starts, saves and resumes without side effects", c do
    assert get(build_conn(), c.path).status == 401
    assert write(c, :post, %{}, csrf: false).status == 403
    assert write(c, :post, %{}, origin: "https://evil.invalid").status == 403
    response = write(c, :post, %{})
    d = json_response(response, 200)["data"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert json_response(get(auth(c.token), c.path), 200)["data"] == d

    attrs = %{
      revision: d["revision"],
      request_id: Ecto.UUID.generate(),
      state: "locations",
      proposal: d["proposal"]
    }

    saved = write(c, :put, attrs) |> json_response(200) |> Map.fetch!("data")
    assert saved["state"] == "locations"
    assert write(c, :put, Map.put(attrs, :request_id, Ecto.UUID.generate())).status == 409
    assert write(c, :put, Map.put(attrs, :owner_id, c.owner.id)).status == 422
    assert json_response(write(c, :put, attrs), 200)["data"] == saved
    assert json_response(get(auth(c.token), c.path), 200)["data"] == saved
  end

  test "Manager denial, wrong business and revoked cookie", c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {_s, t} = session_fixture(manager)
    assert get(auth(t), c.path).status == 403
    other = other_business_price_fixture().shop

    assert get(auth(c.token), "/api/admin/businesses/#{other.business_id}/onboarding").status ==
             403

    Accounts.revoke_session(c.session, :logout)
    assert get(auth(c.token), c.path).status == 401
  end
end
