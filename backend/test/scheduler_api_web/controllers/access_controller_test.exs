defmodule SchedulerApiWeb.AccessControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import Ecto.Query
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Organizations.{Business, BusinessMembership, RoleAssignment}
  alias SchedulerApiWeb.BrowserSession

  setup do
    shop = shop_fixture()
    business = Repo.get!(Business, shop.business_id)
    owner = active_user_fixture()
    {owner_m, owner_r} = grant_fixture(owner, shop, :business_owner)
    manager = active_user_fixture()
    {manager_m, manager_r} = grant_fixture(manager, shop, :business_manager)
    target = active_user_fixture()
    membership = Repo.insert!(%BusinessMembership{user_id: target.id, business_id: business.id})

    %{
      business: business,
      shop: shop,
      owner: owner,
      owner_m: owner_m,
      owner_r: owner_r,
      manager: manager,
      manager_m: manager_m,
      manager_r: manager_r,
      target: target,
      membership: membership
    }
  end

  defp base(c), do: "/api/admin/businesses/#{c.business.id}"
  defp token(u), do: session_fixture(u) |> elem(1)
  defp auth(t), do: put_req_cookie(build_conn(), BrowserSession.session_name(), t)

  defp request(t, method, path, body \\ %{}, opts \\ []) do
    conn = if t, do: auth(t), else: build_conn()

    if method == :get do
      get(conn, path)
    else
      csrf = if t, do: auth(t) |> get("/api/me") |> json_response(200) |> Map.get("csrf_token")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", Keyword.get(opts, :origin, "http://localhost:5173"))

      conn =
        if csrf && Keyword.get(opts, :csrf, true),
          do: put_req_header(conn, "x-csrf-token", csrf),
          else: conn

      post(conn, path, if(is_binary(body), do: body, else: Jason.encode!(body)))
    end
  end

  defp body(c, role \\ "employee"),
    do: %{
      membership_id: c.membership.id,
      role: role,
      shop_id: if(role in ["employee", "shop_manager"], do: c.shop.id)
    }

  test "sessions CSRF origin and bounded JSON are enforced before access writes", c do
    path = base(c) <> "/role-grants"

    for method <- [:get, :post],
        do:
          assert(
            json_response(request(nil, method, path), 401) == %{
              "error" => "authentication_required"
            }
          )

    t = token(c.owner)

    assert json_response(request(t, :post, path, body(c), csrf: false), 403)["error"] ==
             "invalid_csrf_token"

    assert json_response(request(t, :post, path, body(c), origin: "https://evil.invalid"), 403)[
             "error"
           ] == "invalid_origin"

    {s, revoked} = session_fixture(c.owner)
    Accounts.revoke_session(s, :logout)
    assert json_response(request(revoked, :get, path), 401)

    {_, expired} =
      session_fixture(c.owner,
        now: DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -3600)
      )

    assert json_response(request(expired, :get, path), 401)

    for status <- [:pending, :suspended, :deactivated] do
      Accounts.set_user_status(c.owner, status)
      assert json_response(request(t, :get, path), 401)
    end
  end

  test "Owner manages every fixed role and memberships without duplicate Manager grant", c do
    t = token(c.owner)

    for role <- ~w(employee shop_manager business_manager business_owner) do
      r = json_response(request(t, :post, base(c) <> "/role-grants", body(c, role)), 201)["data"]
      assert r["role"] == role and r["membership_id"] == c.membership.id

      assert Enum.sort(Map.keys(r)) ==
               Enum.sort(
                 ~w(id business_id membership_id role shop_id status inserted_at revoked_at)
               )

      assert json_response(request(t, :post, base(c) <> "/role-grants/#{r["id"]}/revoke"), 200)[
               "data"
             ]["status"] == "revoked"
    end

    assert json_response(
             request(t, :post, base(c) <> "/memberships/#{c.membership.id}/revoke"),
             200
           )

    assert json_response(
             request(t, :post, base(c) <> "/memberships/#{c.membership.id}/reactivate"),
             200
           )

    refute Repo.exists?(
             from r in RoleAssignment,
               where: r.membership_id == ^c.membership.id and r.status == :active
           )

    assert json_response(request(t, :post, base(c) <> "/role-grants/#{c.owner_r.id}/revoke"), 409)[
             "error"
           ] == "last_owner"
  end

  test "Manager delegates lower roles but cannot self-promote or manage protected roles or memberships",
       c do
    t = token(c.manager)

    for role <- ~w(employee shop_manager) do
      r = json_response(request(t, :post, base(c) <> "/role-grants", body(c, role)), 201)["data"]
      assert json_response(request(t, :post, base(c) <> "/role-grants/#{r["id"]}/revoke"), 200)

      assert json_response(
               request(t, :post, base(c) <> "/role-grants", %{
                 body(c, role)
                 | membership_id: c.manager_m.id
               }),
               403
             )
    end

    for role <- ~w(business_manager business_owner),
        do:
          assert(json_response(request(t, :post, base(c) <> "/role-grants", body(c, role)), 403))

    for action <- ~w(revoke reactivate),
        do:
          assert(
            json_response(
              request(t, :post, base(c) <> "/memberships/#{c.membership.id}/#{action}"),
              403
            )
          )

    assert json_response(request(t, :post, base(c) <> "/role-grants/#{c.owner_r.id}/revoke"), 403)

    assert json_response(
             request(t, :post, base(c) <> "/role-grants/#{c.manager_r.id}/revoke"),
             403
           )
  end

  test "scoped lists exclude protected targets and upper-role history before pagination", c do
    ot = token(c.owner)
    mt = token(c.manager)
    r = json_response(request(ot, :post, base(c) <> "/role-grants", body(c)), 201)["data"]
    page = json_response(request(mt, :get, base(c) <> "/memberships?limit=1"), 200)["data"]
    assert Enum.map(page["items"], & &1["id"]) == [c.membership.id]
    refute page["has_more"]

    assert json_response(request(mt, :get, base(c) <> "/role-grants"), 200)["data"]["items"]
           |> Enum.map(& &1["id"]) == [r["id"]]

    cursor =
      json_response(request(ot, :get, base(c) <> "/memberships?limit=1"), 200)["data"][
        "next_cursor"
      ]

    assert is_binary(cursor)
    assert json_response(request(mt, :get, base(c) <> "/memberships?cursor=#{cursor}"), 422)
    assert json_response(request(ot, :get, base(c) <> "/role-grants?cursor=#{cursor}"), 422)

    assert json_response(
             request(ot, :get, base(c) <> "/memberships?status=revoked&cursor=#{cursor}"),
             422
           )

    assert get_resp_header(request(ot, :get, base(c) <> "/memberships"), "cache-control") == [
             "no-store"
           ]

    assert json_response(request(ot, :post, base(c) <> "/role-grants/#{r["id"]}/revoke"), 200)

    history =
      json_response(request(mt, :get, base(c) <> "/role-grants?status=revoked"), 200)["data"][
        "items"
      ]

    assert Enum.map(history, & &1["id"]) == [r["id"]]
  end

  test "Shop Managers Employees and cross-business grants do not authorize staff access", c do
    for role <- [:employee, :shop_manager] do
      u = active_user_fixture()
      grant_fixture(u, c.shop, role)
      t = token(u)
      assert json_response(request(t, :get, base(c) <> "/memberships"), 403)
      assert json_response(request(t, :post, base(c) <> "/role-grants", body(c)), 403)
    end

    other_business = Repo.insert!(%Business{name: "Foreign", slug: "foreign-access"})
    foreign = shop_fixture(%{business_id: other_business.id})
    grant_fixture(c.manager, foreign, :business_owner)
    t = token(c.manager)

    assert json_response(
             request(t, :post, base(c) <> "/role-grants", body(c, "business_manager")),
             403
           )

    assert json_response(
             request(
               token(c.owner),
               :get,
               "/api/admin/businesses/#{foreign.business_id}/memberships"
             ),
             403
           )

    assert json_response(
             request(t, :post, base(c) <> "/role-grants", %{body(c) | shop_id: foreign.id}),
             422
           )

    # The same human owning both tenants still cannot move a target across businesses.
    grant_fixture(c.owner, foreign, :business_owner)

    assert json_response(
             request(
               token(c.owner),
               :post,
               "/api/admin/businesses/#{foreign.business_id}/role-grants",
               body(c)
             ),
             403
           )
  end

  test "revocations immediately invalidate delegation while keeping otherwise-valid session", c do
    ot = token(c.owner)
    mt = token(c.manager)

    assert json_response(
             request(ot, :post, base(c) <> "/role-grants/#{c.manager_r.id}/revoke"),
             200
           )

    assert json_response(request(mt, :get, base(c) <> "/memberships"), 403)
    assert json_response(request(mt, :post, base(c) <> "/role-grants", body(c)), 403)
    assert json_response(request(mt, :get, "/api/me"), 200)["authenticated"]
  end

  test "membership revocation cascades and explicit reactivation leaves stale session powerless",
       c do
    ot = token(c.owner)
    mt = token(c.manager)

    assert json_response(
             request(ot, :post, base(c) <> "/memberships/#{c.manager_m.id}/revoke"),
             200
           )

    assert Repo.get!(RoleAssignment, c.manager_r.id).status == :revoked
    assert json_response(request(mt, :get, base(c) <> "/memberships"), 403)

    assert json_response(
             request(ot, :post, base(c) <> "/memberships/#{c.manager_m.id}/reactivate"),
             200
           )

    assert json_response(request(mt, :get, base(c) <> "/memberships"), 403)
    assert json_response(request(mt, :post, base(c) <> "/role-grants", body(c)), 403)
  end

  test "cursor and records remain isolated for one Owner with two independent businesses", c do
    t = token(c.owner)

    cursor =
      json_response(request(t, :get, base(c) <> "/memberships?limit=1"), 200)["data"][
        "next_cursor"
      ]

    page2 =
      json_response(request(t, :get, base(c) <> "/memberships?cursor=#{cursor}"), 200)["data"]

    assert Enum.map(page2["items"], & &1["id"]) == [c.manager_m.id, c.membership.id]
    other = Repo.insert!(%Business{name: "Separate tenant", slug: "separate-access"})
    shop = shop_fixture(%{business_id: other.id})
    {other_m, _} = grant_fixture(c.owner, shop, :business_owner)
    path = "/api/admin/businesses/#{other.id}/memberships"
    assert json_response(request(t, :get, path <> "?cursor=#{cursor}"), 422)
    items = json_response(request(t, :get, path), 200)["data"]["items"]
    assert Enum.map(items, & &1["id"]) == [other_m.id]
    assert Enum.all?(items, &(&1["business_id"] == other.id))
  end

  test "malformed injected parameters and audit failure fail safely without partial mutation",
       c do
    t = token(c.owner)

    for payload <- [
          "{",
          Jason.encode!(%{padding: String.duplicate("x", 65000)}),
          [1],
          Map.put(body(c), :user_id, c.owner.id),
          Map.put(body(c), :status, "active"),
          Map.put(body(c), :business_id, c.business.id),
          %{body(c) | role: "god_mode"},
          %{body(c) | membership_id: []}
        ] do
      assert json_response(request(t, :post, base(c) <> "/role-grants", payload), 422)
    end

    for query <- ["limit=101", "cursor=bad", "status=all", "shop_id=1", "business_id=1"],
        do: assert(json_response(request(t, :get, base(c) <> "/memberships?#{query}"), 422))

    Repo.query!(
      "ALTER TABLE authorization_audit_events ADD CONSTRAINT test_http_access_audit CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert json_response(request(t, :post, base(c) <> "/role-grants", body(c)), 503) == %{
             "error" => "operation_unavailable"
           }

    refute Repo.exists?(from r in RoleAssignment, where: r.membership_id == ^c.membership.id)
  end

  test "Owner and Manager grants remain independent after either grant is removed", c do
    owner_token = token(c.owner)

    manager_grant =
      json_response(
        request(owner_token, :post, base(c) <> "/role-grants", %{
          membership_id: c.owner_m.id,
          role: "business_manager"
        }),
        201
      )["data"]

    assert json_response(
             request(owner_token, :post, base(c) <> "/role-grants/#{manager_grant["id"]}/revoke"),
             200
           )

    assert json_response(
             request(owner_token, :post, base(c) <> "/role-grants", body(c, "business_owner")),
             201
           )

    assert json_response(
             request(owner_token, :post, base(c) <> "/role-grants", %{
               membership_id: c.owner_m.id,
               role: "business_manager"
             }),
             201
           )

    assert json_response(
             request(owner_token, :post, base(c) <> "/role-grants/#{c.owner_r.id}/revoke"),
             200
           )

    # A remaining Manager grant cannot supply the former Owner's privileges or target protection exception.
    assert json_response(
             request(owner_token, :post, base(c) <> "/role-grants", body(c, "business_manager")),
             403
           )

    assert json_response(
             request(owner_token, :post, base(c) <> "/memberships/#{c.membership.id}/revoke"),
             403
           )
  end

  test "Owner-grant history and revoked memberships stay protected from delegation", c do
    ot = token(c.owner)
    mt = token(c.manager)

    owner_grant =
      json_response(request(ot, :post, base(c) <> "/role-grants", body(c, "business_owner")), 201)[
        "data"
      ]

    assert json_response(
             request(ot, :post, base(c) <> "/role-grants/#{owner_grant["id"]}/revoke"),
             200
           )

    lower = json_response(request(ot, :post, base(c) <> "/role-grants", body(c)), 201)["data"]
    assert json_response(request(mt, :post, base(c) <> "/role-grants/#{lower["id"]}/revoke"), 403)

    assert json_response(request(mt, :get, base(c) <> "/role-grants?status=revoked"), 200)["data"][
             "items"
           ] == []

    assert json_response(
             request(ot, :post, base(c) <> "/memberships/#{c.membership.id}/revoke"),
             200
           )

    assert json_response(
             request(mt, :post, base(c) <> "/role-grants", body(c, "shop_manager")),
             403
           )
  end

  test "current tenant eligibility and email verification override stale cookies", c do
    t = token(c.owner)
    Repo.update!(Ecto.Changeset.change(c.owner, email_verified: false))
    assert json_response(request(t, :get, base(c) <> "/memberships"), 401)
    Repo.update!(Ecto.Changeset.change(Repo.reload!(c.owner), email_verified: true))
    t = token(c.owner)
    Repo.update!(Ecto.Changeset.change(c.business, status: :archived))
    assert json_response(request(t, :get, base(c) <> "/memberships"), 403)
    assert json_response(request(t, :post, base(c) <> "/role-grants", body(c)), 403)
  end

  test "historical Owner classification cannot be bypassed by lower grants or history selectors",
       c do
    e =
      SchedulerApi.EmploymentFixtures.employment_fixture(%{classification: :business_owner},
        business: c.business,
        user: c.target
      )

    {:ok, _, cred} = Accounts.create_session(c.owner)
    {:ok, _} = SchedulerApi.Employment.HR.change_classification(cred, e, :detailer)
    ot = token(c.owner)
    r = json_response(request(ot, :post, base(c) <> "/role-grants", body(c)), 201)["data"]
    mt = token(c.manager)
    assert json_response(request(mt, :post, base(c) <> "/role-grants/#{r["id"]}/revoke"), 403)

    assert json_response(
             request(mt, :post, base(c) <> "/role-grants", body(c, "shop_manager")),
             403
           )

    assert json_response(request(mt, :get, base(c) <> "/memberships"), 200)["data"]["items"] == []
  end
end
