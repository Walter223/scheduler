defmodule SchedulerApiWeb.EmployeeWriteControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import Ecto.Query
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Employment.{HR, EmploymentRecord, RehireAudit}
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()
  defp base(c), do: "/api/admin/businesses/#{c.business.id}/employees"

  defp period(c, e \\ nil) do
    e = e || c.employment
    base(c) <> "/#{e.employee_id}/periods/#{e.id}"
  end

  defp token(user), do: session_fixture(user) |> elem(1)
  defp auth(token), do: put_req_cookie(build_conn(), BrowserSession.session_name(), token)

  defp csrf(token),
    do: auth(token) |> get("/api/me") |> json_response(200) |> Map.fetch!("csrf_token")

  defp request(token, method, path, body \\ %{}, opts \\ []) do
    c = if token, do: auth(token), else: build_conn()

    c =
      c
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", Keyword.get(opts, :origin, "http://localhost:5173"))

    c =
      if Keyword.get(opts, :csrf, true),
        do: put_req_header(c, "x-csrf-token", Keyword.get(opts, :value) || csrf(token) || "bad"),
        else: c

    dispatch(c, @endpoint, method, path, Jason.encode!(body))
  end

  defp attrs,
    do: %{
      first_name: "Jamie",
      last_name: "HR",
      classification: "detailer",
      starts_on: "2026-01-01"
    }

  test "anonymous expired revoked and cross-session CSRF requests fail safely", c do
    path = base(c)

    assert json_response(request(nil, :post, path, attrs(), csrf: false), 401) == %{
             "error" => "authentication_required"
           }

    {session, raw} = session_fixture(c.owner)

    assert json_response(request(raw, :post, path, attrs(), csrf: false), 403)["error"] ==
             "invalid_csrf_token"

    other = token(c.detailer)

    assert json_response(request(raw, :post, path, attrs(), value: csrf(other)), 403)["error"] ==
             "invalid_csrf_token"

    assert json_response(request(raw, :post, path, attrs(), origin: "https://evil.test"), 403)[
             "error"
           ] == "invalid_origin"

    valid = csrf(raw)
    {:ok, _} = Accounts.revoke_session(session, :logout)

    assert json_response(request(raw, :post, path, attrs(), value: valid), 401)["error"] ==
             "authentication_required"

    {_, expired} =
      session_fixture(c.owner,
        now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)
      )

    assert json_response(request(expired, :post, path, attrs(), value: valid), 401)["error"] ==
             "authentication_required"
  end

  test "Owner and Business Manager use all permitted create contact classification and shop operations",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)

    for user <- [c.owner, manager] do
      raw = token(user)
      response = request(raw, :post, base(c), attrs())
      created = json_response(response, 201)["data"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert created["employee_id"] == created["period_id"]
      e = Repo.get!(EmploymentRecord, created["period_id"])
      assert is_nil(e.user_id)

      assert json_response(
               request(raw, :patch, period(c, e) <> "/contact", %{
                 phone: "555",
                 home_address: "Private"
               }),
               200
             )["data"]["phone"] == "555"

      assert json_response(
               request(raw, :patch, period(c, e) <> "/classification", %{
                 classification: "business_manager"
               }),
               200
             )["data"]["classification"] == "business_manager"

      assigned =
        json_response(
          request(raw, :post, period(c, e) <> "/shop-assignments", %{
            shop_id: c.shop.id,
            starts_on: "2026-01-01"
          }),
          201
        )["data"]

      assert assigned["period_id"] == e.id

      assert json_response(
               request(
                 raw,
                 :post,
                 period(c, e) <> "/shop-assignments/#{assigned["assignment_id"]}/end",
                 %{ends_on: "2026-10-30"}
               ),
               200
             )["data"]["status"] == "ended"

      for field <- ~w(user_id amount csrf_state token audit),
          do: refute(Map.has_key?(created, field))
    end
  end

  test "Employee Shop Manager and foreign tenant selectors never authorize writes", c do
    for role <- [:shop_manager, :employee] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, role)
      raw = token(user)

      for {method, path, body} <- [
            {:post, base(c), attrs()},
            {:patch, period(c) <> "/contact", %{phone: "x"}},
            {:post, period(c) <> "/terminate", %{}},
            {:post, period(c) <> "/rehire", %{starts_on: "2026-11-01"}}
          ] do
        assert json_response(request(raw, method, path, body), 403) == %{"error" => "forbidden"}
      end
    end

    foreign = job_fixture()
    raw = token(c.owner)

    assert json_response(request(raw, :post, base(foreign), attrs()), 403) == %{
             "error" => "forbidden"
           }

    assert json_response(
             request(
               raw,
               :patch,
               base(c) <>
                 "/#{foreign.employment.employee_id}/periods/#{foreign.employment.id}/contact",
               %{phone: "x"}
             ),
             403
           ) == %{"error" => "forbidden"}

    assert json_response(
             request(raw, :post, period(c) <> "/shop-assignments", %{
               shop_id: foreign.shop.id,
               starts_on: "2026-01-01"
             }),
             422
           ) == %{"error" => "invalid_input"}
  end

  test "explicit allowlists reject ownership grants links pay and query overrides", c do
    raw = token(c.owner)

    for key <-
          ~w(business_id employee_id period_id shop_id user_id status role amount audit_metadata) do
      assert json_response(request(raw, :patch, period(c) <> "/contact", %{key => 1}), 422) == %{
               "error" => "invalid_input"
             }
    end

    assert json_response(
             request(raw, :post, base(c), Map.put(attrs(), :user_id, c.detailer.id)),
             422
           )["error"] == "invalid_input"

    assert json_response(
             request(raw, :post, period(c) <> "/terminate", %{ends_on: "2020-01-01"}),
             422
           )["error"] == "invalid_input"

    assert json_response(
             request(raw, :patch, period(c) <> "/contact?business_id=1", %{phone: "x"}),
             422
           )["error"] == "invalid_input"

    assert json_response(
             request(raw, :patch, period(c) <> "/classification", %{classification: "god_mode"}),
             422
           )["error"] == "invalid_input"
  end

  test "termination and rehire preserve history, revoke only one business and restore nothing",
       c do
    foreign = job_fixture()
    {other_member, _} = grant_fixture(c.detailer, foreign.shop, :business_manager)
    other = employment_fixture(%{}, business: foreign.business, user: c.detailer)
    raw = token(c.owner)
    old_cookie = token(c.detailer)

    assert json_response(request(raw, :post, period(c) <> "/terminate"), 200)["data"][
             "employment"
           ]["status"] == "ended"

    assert Repo.reload!(c.employee_membership).status == :revoked
    assert Repo.reload!(other_member).status == :active and Repo.reload!(other).status == :active

    assert json_response(request(raw, :post, period(c) <> "/terminate"), 200)["data"][
             "already_terminated"
           ]

    date = Date.add(Date.utc_today(), 1) |> Date.to_iso8601()

    new =
      json_response(request(raw, :post, period(c) <> "/rehire", %{starts_on: date}), 201)["data"]

    assert new["employee_id"] == c.employment.id and new["period_id"] != c.employment.id
    assert Repo.reload!(c.employment).status == :ended

    refute Repo.exists?(
             from a in SchedulerApi.Employment.ShopAssignment,
               where: a.employment_id == ^new["period_id"]
           )

    assert Repo.aggregate(RehireAudit, :count) == 1

    assert json_response(request(raw, :post, period(c) <> "/rehire", %{starts_on: date}), 409)[
             "error"
           ] == "not_latest_ended_period"

    assert json_response(auth(old_cookie) |> get(base(c) <> "/#{c.employment.id}/periods"), 403)[
             "error"
           ] == "forbidden"

    assert json_response(auth(old_cookie) |> get(base(foreign)), 200)
  end

  test "Business Manager cannot terminate current or historical Owner classification without grants",
       c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    raw = token(manager)
    e = employment_fixture(%{classification: :business_owner}, business: c.business)

    assert json_response(request(raw, :post, period(c, e) <> "/terminate"), 403) == %{
             "error" => "forbidden"
           }

    {:ok, _} = HR.change_classification(c.credential, e, :detailer)

    assert json_response(request(raw, :post, period(c, e) <> "/terminate"), 403) == %{
             "error" => "forbidden"
           }

    assert json_response(
             request(token(c.owner), :post, period(c) <> "/rehire", %{starts_on: "bad"}),
             409
           )["error"] == "not_latest_ended_period"
  end

  test "outstanding work and invalid date transitions are safe explicit errors", c do
    raw = token(c.owner)

    assert json_response(
             request(raw, :patch, period(c) <> "/classification", %{
               classification: "shop_manager"
             }),
             409
           )["error"] == "outstanding_work"

    assert json_response(
             request(raw, :post, period(c) <> "/shop-assignments/#{c.assignment.id}/end", %{
               ends_on: "bad"
             }),
             422
           )["error"] == "invalid_input"

    assert json_response(
             request(raw, :post, period(c) <> "/shop-assignments", %{
               shop_id: c.shop.id,
               starts_on: "2026-01-01"
             }),
             409
           )["error"] == "already_assigned"

    assert json_response(
             request(raw, :post, base(c) <> "/#{c.employment.id}/periods/999999/terminate"),
             403
           )["error"] == "forbidden"
  end

  test "audit failure yields generic 503 and rolls back the domain mutation", c do
    Repo.query!(
      "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT test_http_hr_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    response = request(token(c.owner), :patch, period(c) <> "/contact", %{phone: "private"})
    assert json_response(response, 503) == %{"error" => "operation_unavailable"}
    assert Repo.reload!(c.employment).phone == nil
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "multiple shop assignments and Business Manager termination/rehire retain explicit period scope",
       c do
    user = active_user_fixture()
    grant_fixture(user, c.shop, :business_manager)
    raw = token(user)
    e = employment_fixture(%{}, business: c.business)
    other = SchedulerApi.ShopsFixtures.shop_fixture(%{business_id: c.business.id})

    for shop <- [c.shop, other] do
      assert json_response(
               request(raw, :post, period(c, e) <> "/shop-assignments", %{
                 shop_id: shop.id,
                 starts_on: "2026-01-01"
               }),
               201
             )["data"]["employee_id"] == e.employee_id
    end

    assert json_response(request(raw, :post, period(c, e) <> "/terminate"), 200)["data"][
             "employment"
           ]["status"] == "ended"

    new =
      json_response(
        request(raw, :post, period(c, e) <> "/rehire", %{
          starts_on: Date.add(Date.utc_today(), 1) |> Date.to_iso8601()
        }),
        201
      )["data"]

    assert new["employee_id"] == e.employee_id

    assert json_response(
             request(
               raw,
               :patch,
               base(c) <> "/#{new["period_id"]}/periods/#{new["period_id"]}/contact",
               %{phone: "x"}
             ),
             403
           )["error"] == "forbidden"
  end

  test "last Owner protection and final offboarding audit failure are atomic over HTTP", c do
    e =
      employment_fixture(%{classification: :business_owner}, business: c.business, user: c.owner)

    raw = token(c.owner)

    assert json_response(request(raw, :post, period(c, e) <> "/terminate"), 409)["error"] ==
             "last_owner"

    Repo.query!(
      "ALTER TABLE employment_offboarding_audits ADD CONSTRAINT test_http_offboarding_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert json_response(request(raw, :post, period(c) <> "/terminate"), 503) == %{
             "error" => "operation_unavailable"
           }

    assert Repo.reload!(c.employee_membership).status == :active
    assert Repo.reload!(c.employment).status == :active
    assert Repo.reload!(c.assignment).status == :active
  end

  test "private JSON parser rejects malformed and oversized bodies after security checks", c do
    raw = token(c.owner)
    valid = csrf(raw)

    for body <- ["{", Jason.encode!(%{first_name: String.duplicate("a", 65_000)})] do
      conn =
        auth(raw)
        |> put_req_header("origin", "http://localhost:5173")
        |> put_req_header("x-csrf-token", valid)
        |> put_req_header("content-type", "application/json")

      assert json_response(post(conn, base(c), body), 422) == %{"error" => "invalid_input"}
    end
  end
end
