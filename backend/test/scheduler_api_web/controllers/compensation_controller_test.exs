defmodule SchedulerApiWeb.CompensationControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import Ecto.Query
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Employment, Repo}
  alias SchedulerApi.Employment.{HR, CompensationRate}
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()

  defp today,
    do:
      DateTime.utc_now()
      |> SchedulerApi.Appointments.Availability.local_datetime()
      |> NaiveDateTime.to_date()

  defp base(c), do: "/api/admin/businesses/#{c.business.id}"

  defp pay_path(c, e \\ nil),
    do:
      base(c) <>
        "/employees/#{(e || c.employment).employee_id}/periods/#{(e || c.employment).id}/compensation"

  defp auth(t), do: put_req_cookie(build_conn(), BrowserSession.session_name(), t)
  defp token(u), do: session_fixture(u) |> elem(1)

  defp req(t, method, path, body \\ %{}, opts \\ []) do
    conn = if t, do: auth(t), else: build_conn()

    if method == :get do
      get(conn, path)
    else
      csrf =
        if t,
          do: auth(t) |> get("/api/me") |> json_response(200) |> Map.get("csrf_token"),
          else: nil

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("origin", Keyword.get(opts, :origin, "http://localhost:5173"))

      conn =
        if csrf && Keyword.get(opts, :csrf, true),
          do: put_req_header(conn, "x-csrf-token", csrf),
          else: conn

      post(conn, path, Jason.encode!(body))
    end
  end

  defp rate(days \\ 0),
    do: %{
      amount: "25.50",
      pay_basis: "hourly",
      effective_from: Date.add(today(), days) |> Date.to_iso8601()
    }

  test "live sessions and CSRF/origin are mandatory", c do
    assert json_response(req(nil, :get, pay_path(c) <> "/current"), 401)["error"] ==
             "authentication_required"

    assert json_response(req(nil, :post, pay_path(c) <> "/rates", rate()), 401)["error"] ==
             "authentication_required"

    t = token(c.owner)

    assert json_response(req(t, :post, pay_path(c) <> "/rates", rate(), csrf: false), 403)[
             "error"
           ] ==
             "invalid_csrf_token"

    assert json_response(
             req(t, :post, pay_path(c) <> "/rates", rate(), origin: "https://evil.test"),
             403
           )["error"] == "invalid_origin"

    {s, revoked} = session_fixture(c.owner)
    {:ok, _} = Accounts.revoke_session(s, :logout)

    assert json_response(req(revoked, :get, pay_path(c) <> "/history"), 401)["error"] ==
             "authentication_required"

    {_, expired} =
      session_fixture(c.owner,
        now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)
      )

    assert json_response(req(expired, :post, pay_path(c) <> "/rates", rate()), 401)["error"] ==
             "authentication_required"
  end

  test "Owner HR writes exact money and reads bounded effective-dated history", c do
    t = token(c.owner)
    first = json_response(req(t, :post, pay_path(c) <> "/rates", rate()), 201)["data"]

    assert first["amount"] == "25.50" and first["period_id"] == c.employment.id and
             first["employee_id"] == c.employment.employee_id

    assert Enum.sort(Map.keys(first)) ==
             Enum.sort(
               ~w(rate_id business_id period_id employee_id amount currency pay_basis effective_from effective_until)
             )

    assert json_response(req(t, :get, pay_path(c) <> "/current"), 200)["data"] == first
    for d <- 1..2, do: assert(json_response(req(t, :post, pay_path(c) <> "/rates", rate(d)), 201))
    page = json_response(req(t, :get, pay_path(c) <> "/history?limit=1"), 200)["data"]
    assert page["has_more"]

    assert length(
             json_response(
               req(t, :get, pay_path(c) <> "/history?cursor=#{page["next_cursor"]}"),
               200
             )[
               "data"
             ]["rates"]
           ) == 2

    assert json_response(req(t, :get, pay_path(c) <> "/history?limit=101"), 422)["error"] ==
             "invalid_input"

    assert get_resp_header(req(t, :get, pay_path(c) <> "/current"), "cache-control") == [
             "no-store"
           ]
  end

  test "Business Manager reads/writes staff pay but never current or historical Owner pay", c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    t = token(manager)
    assert json_response(req(t, :post, pay_path(c) <> "/rates", rate()), 201)
    assert json_response(req(t, :get, pay_path(c) <> "/history"), 200)
    e = employment_fixture(%{classification: :business_owner}, business: c.business)
    assert json_response(req(t, :get, pay_path(c, e) <> "/current"), 403)["error"] == "forbidden"
    {:ok, _} = HR.change_classification(c.credential, e, :detailer)

    for {method, suffix, body} <- [
          {:get, "/history", %{}},
          {:get, "/current", %{}},
          {:post, "/rates", rate()}
        ] do
      assert json_response(req(t, method, pay_path(c, e) <> suffix, body), 403)["error"] ==
               "forbidden"
    end
  end

  test "Shop Manager current Detailer pay only, never history/write or historical management compensation",
       c do
    t = token(c.owner)
    assert json_response(req(t, :post, pay_path(c) <> "/rates", rate()), 201)
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    raw = token(sm)

    assert json_response(req(raw, :get, pay_path(c) <> "/current"), 200)["data"]["amount"] ==
             "25.50"

    assert json_response(req(raw, :get, pay_path(c) <> "/history"), 403)["error"] == "forbidden"

    assert json_response(req(raw, :post, pay_path(c) <> "/rates", rate(1)), 403)["error"] ==
             "forbidden"

    e = employment_fixture(%{classification: :shop_manager}, business: c.business)
    {:ok, _} = Employment.assign_shop(e, c.shop, %{starts_on: ~D[2026-01-01]})
    {:ok, _} = HR.change_classification(c.credential, e, :detailer)

    assert json_response(req(raw, :get, pay_path(c, e) <> "/current"), 403)["error"] ==
             "forbidden"
  end

  test "multiple shops and foreign-business scopes never combine", c do
    t = token(c.owner)
    req(t, :post, pay_path(c) <> "/rates", rate())
    other = shop_fixture(%{business_id: c.business.id})
    sm = active_user_fixture()
    grant_fixture(sm, other, :shop_manager)
    raw = token(sm)
    assert json_response(req(raw, :get, pay_path(c) <> "/current"), 403)["error"] == "forbidden"
    {:ok, _} = Employment.assign_shop(c.employment, other, %{starts_on: ~D[2026-01-01]})
    assert json_response(req(raw, :get, pay_path(c) <> "/current"), 200)
    foreign = job_fixture()

    assert json_response(req(t, :get, pay_path(foreign) <> "/current"), 403)["error"] ==
             "forbidden"

    assert json_response(req(t, :get, pay_path(c) <> "/current?shop_id=#{foreign.shop.id}"), 422)[
             "error"
           ] == "invalid_input"
  end

  test "own-pay is current period only; HR retains old history after termination and rehire", c do
    t = token(c.owner)
    raw = token(c.detailer)
    req(t, :post, pay_path(c) <> "/rates", rate())

    assert json_response(req(raw, :get, base(c) <> "/me/compensation/current"), 200)["data"][
             "amount"
           ] == "25.50"

    assert json_response(req(raw, :get, pay_path(c) <> "/current"), 403)["error"] == "forbidden"
    {:ok, _} = HR.terminate_employment(c.credential, c.employment)

    assert json_response(req(raw, :get, base(c) <> "/me/compensation/current"), 403)["error"] ==
             "forbidden"

    {:ok, new} = HR.rehire_employment(c.credential, c.employment, Date.add(today(), 1))
    assert json_response(req(raw, :get, pay_path(c) <> "/history"), 403)["error"] == "forbidden"
    assert json_response(req(t, :get, pay_path(c) <> "/current"), 200)["data"] == nil

    assert length(json_response(req(t, :get, pay_path(c) <> "/history"), 200)["data"]["rates"]) ==
             1

    refute Repo.exists?(from r in CompensationRate, where: r.employment_id == ^new.id)
  end

  test "payload injection precision overlap dates and scope-bound history cursor fail safely",
       c do
    t = token(c.owner)

    for body <- [
          Map.put(rate(), :user_id, 1),
          Map.put(rate(), :amount, 1.25),
          Map.put(rate(), :amount, "1.001"),
          Map.put(rate(), :amount, "NaN"),
          rate(-1)
        ] do
      assert json_response(req(t, :post, pay_path(c) <> "/rates", body), 422)["error"] ==
               "invalid_input"
    end

    req(t, :post, pay_path(c) <> "/rates", rate())
    req(t, :post, pay_path(c) <> "/rates", rate(1))

    assert json_response(req(t, :post, pay_path(c) <> "/rates", rate()), 409)["error"] ==
             "effective_date_conflict"

    cursor =
      json_response(req(t, :get, pay_path(c) <> "/history?limit=1"), 200)["data"]["next_cursor"]

    other = employment_fixture(%{}, business: c.business)

    assert json_response(req(t, :get, pay_path(c, other) <> "/history?cursor=#{cursor}"), 422)[
             "error"
           ] == "invalid_input"

    assert json_response(
             req(
               t,
               :get,
               base(c) <>
                 "/employees/#{other.employee_id}/periods/#{c.employment.id}/compensation/current"
             ),
             403
           )["error"] == "forbidden"
  end

  test "audit failure rolls back financial insert and exposes no SQL or amount", c do
    Repo.query!(
      "ALTER TABLE compensation_audit_events ADD CONSTRAINT test_http_pay_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert json_response(req(token(c.owner), :post, pay_path(c) <> "/rates", rate()), 503) == %{
             "error" => "operation_unavailable"
           }

    assert Repo.aggregate(CompensationRate, :count) == 0
  end

  test "Owner classification history still protects the rehired period with no Owner grant", c do
    e = employment_fixture(%{classification: :business_owner}, business: c.business)
    {:ok, _} = HR.change_classification(c.credential, e, :detailer)
    {:ok, _} = HR.terminate_employment(c.credential, e)
    {:ok, new} = HR.rehire_employment(c.credential, e, Date.add(today(), 1))
    period = Repo.get!(SchedulerApi.Employment.EmploymentRecord, new.id)

    assert json_response(
             req(token(c.owner), :post, pay_path(c, period) <> "/rates", rate(1)),
             201
           )

    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    raw = token(manager)

    assert json_response(req(raw, :get, pay_path(c, period) <> "/history"), 403)["error"] ==
             "forbidden"

    assert json_response(req(raw, :get, pay_path(c, period) <> "/current"), 403)["error"] ==
             "forbidden"
  end
end
