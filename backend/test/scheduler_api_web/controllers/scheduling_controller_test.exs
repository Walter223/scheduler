defmodule SchedulerApiWeb.SchedulingControllerTest do
  use SchedulerApiWeb.ConnCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Repo}
  alias SchedulerApi.Employment.HR
  alias SchedulerApi.Appointments.{JobAssignments, JobAssignment}
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()
  defp base(c), do: "/api/admin/businesses/#{c.business.id}"
  defp shop(c), do: base(c) <> "/shops/#{c.shop.id}"
  defp team(c), do: shop(c) <> "/appointments/#{c.booking.id}/team"

  defp attrs(c),
    do: %{
      employee_id: c.employment.employee_id,
      period_id: c.employment.id,
      assignment_id: c.assignment.id
    }

  defp token(u), do: session_fixture(u) |> elem(1)
  defp auth(t), do: put_req_cookie(build_conn(), BrowserSession.session_name(), t)

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

      dispatch(conn, @endpoint, method, path, Jason.encode!(body))
    end
  end

  test "anonymous expired revoked and stale account sessions deny reads and writes", c do
    for t <- [nil, "bad"] do
      assert json_response(req(t, :get, shop(c) <> "/shifts"), 401)["error"] ==
               "authentication_required"

      assert json_response(req(t, :post, team(c), attrs(c)), 401)["error"] ==
               "authentication_required"
    end

    for mode <- [:expired, :revoked] do
      opts =
        if mode == :expired,
          do: [now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)],
          else: []

      {s, t} = session_fixture(c.owner, opts)
      if mode == :revoked, do: Accounts.revoke_session(s, :logout)
      assert json_response(req(t, :get, team(c)), 401)["error"] == "authentication_required"
    end

    t = token(c.owner)
    {:ok, _} = Accounts.set_user_status(c.owner, :suspended)
    assert json_response(req(t, :get, team(c)), 401)["error"] == "authentication_required"
  end

  test "Owner team addition removal lead transfer and clear preserve unrelated members", c do
    t = token(c.owner)
    other = second_detailer(c)
    first = json_response(req(t, :post, team(c), attrs(c)), 201)["data"]

    second =
      json_response(
        req(t, :post, team(c), %{
          employee_id: other.employment.employee_id,
          period_id: other.employment.id,
          assignment_id: other.assignment.id
        }),
        201
      )["data"]

    for j <- [first, second] do
      assert json_response(req(t, :post, team(c) <> "/#{j["id"]}/lead"), 200)["data"]["is_lead"]
    end

    members = json_response(req(t, :get, team(c)), 200)["data"]["assignments"]
    assert Enum.count(members, & &1["is_lead"]) == 1
    assert json_response(req(t, :post, team(c) <> "/clear-lead"), 200)
    assert json_response(req(t, :post, team(c) <> "/#{first["id"]}/remove"), 200)
    assert [remaining] = json_response(req(t, :get, team(c)), 200)["data"]["assignments"]
    assert remaining["id"] == second["id"]
    assert json_response(req(t, :post, team(c), attrs(c)), 201)
    assert json_response(req(t, :post, team(c), attrs(c)), 409)["error"] == "already_assigned"

    for f <- ~w(customer_email home_address amount token user_id),
        do: refute(Map.has_key?(remaining, f))
  end

  test "shop appointments preserve existing contract and paginate strictly in that shop", c do
    t = token(c.owner)
    foreign = job_fixture()
    body = json_response(req(t, :get, shop(c) <> "/appointments"), 200)
    assert Enum.map(body["appointments"], & &1["id"]) == [c.booking.id]
    assert body["meta"]["timezone"] == "America/Denver"

    assert json_response(req(t, :get, shop(foreign) <> "/appointments"), 403)["error"] ==
             "forbidden"

    grant_fixture(c.owner, foreign.shop, :business_owner)

    assert hd(json_response(req(t, :get, shop(foreign) <> "/appointments"), 200)["appointments"])[
             "id"
           ] == foreign.booking.id

    assert json_response(req(token(foreign.owner), :get, shop(c) <> "/appointments"), 403)[
             "error"
           ] == "forbidden"
  end

  test "Shop Manager manages only explicitly granted shop and HR/Employee cannot borrow scope",
       c do
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    t = token(sm)
    assert json_response(req(t, :post, team(c), attrs(c)), 201)
    other = shop_fixture(%{business_id: c.business.id})

    assert json_response(req(t, :get, base(c) <> "/shops/#{other.id}/shifts"), 403)["error"] ==
             "forbidden"

    for role <- [:business_manager, :employee] do
      u = active_user_fixture()
      grant_fixture(u, c.shop, role)
      raw = token(u)
      assert json_response(req(raw, :post, team(c), attrs(c)), 403)["error"] == "forbidden"
      assert json_response(req(raw, :get, shop(c) <> "/shifts"), 403)["error"] == "forbidden"
    end
  end

  test "shift create reschedule cancel, explicit employee IDs and overlap conflicts", c do
    t = token(c.owner)

    later = %{
      starts_at: DateTime.add(c.shift.starts_at, 86400),
      ends_at: DateTime.add(c.shift.ends_at, 86400)
    }

    created =
      json_response(req(t, :post, shop(c) <> "/shifts", Map.merge(attrs(c), later)), 201)["data"]

    assert json_response(req(t, :post, shop(c) <> "/shifts", Map.merge(attrs(c), later)), 409)[
             "error"
           ] == "overlap"

    assert json_response(
             req(t, :post, shop(c) <> "/shifts/#{created["id"]}/reschedule", %{
               starts_at: DateTime.add(c.shift.starts_at, 2 * 86400),
               ends_at: DateTime.add(c.shift.ends_at, 2 * 86400)
             }),
             200
           )

    assert json_response(req(t, :post, shop(c) <> "/shifts/#{created["id"]}/cancel"), 409)[
             "error"
           ] == "not_active"

    path = shop(c) <> "/employees/#{c.employment.employee_id}/periods/#{c.employment.id}/shifts"
    page = json_response(req(t, :get, path <> "?limit=1"), 200)["data"]
    assert page["has_more"]
    assert json_response(req(t, :get, path <> "?cursor=#{page["next_cursor"]}"), 200)
    assert json_response(req(t, :get, path <> "?limit=101"), 422)["error"] == "invalid_input"
  end

  test "coverage required and schedule changes with jobs blocked", c do
    t = token(c.owner)
    j = json_response(req(t, :post, team(c), attrs(c)), 201)["data"]

    assert json_response(req(t, :post, shop(c) <> "/shifts/#{c.shift.id}/cancel"), 409)["error"] ==
             "assigned_jobs"

    assert json_response(
             req(t, :post, shop(c) <> "/shifts/#{c.shift.id}/reschedule", %{
               starts_at: c.shift.starts_at,
               ends_at: DateTime.add(c.shift.ends_at, 3600)
             }),
             409
           )["error"] == "assigned_jobs"

    assert json_response(req(t, :post, team(c) <> "/#{j["id"]}/remove"), 200)
    assert json_response(req(t, :post, shop(c) <> "/shifts/#{c.shift.id}/cancel"), 200)

    assert json_response(req(t, :post, team(c), attrs(c)), 409)["error"] ==
             "missing_covering_shift"
  end

  test "own current-period reads never provide coworker or historical period work after rehire",
       c do
    {:ok, j} = JobAssignments.add_member(c.credential, c.booking, c.assignment)
    t = token(c.detailer)

    assert hd(json_response(req(t, :get, base(c) <> "/me/work"), 200)["data"]["assignments"])[
             "id"
           ] == j.id

    assert hd(json_response(req(t, :get, base(c) <> "/me/shifts"), 200)["data"]["shifts"])["id"] ==
             c.shift.id

    assert json_response(req(t, :get, team(c)), 403)["error"] == "forbidden"
    {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    assert json_response(req(t, :get, base(c) <> "/me/work"), 403)["error"] == "forbidden"
    {:ok, _} = HR.rehire_employment(c.credential, c.employment, Date.add(Date.utc_today(), 1))
    assert json_response(req(t, :get, base(c) <> "/me/shifts"), 403)["error"] == "forbidden"
  end

  test "CSRF origin strict fields and wrong-shop identifiers reject without writes", c do
    t = token(c.owner)

    assert json_response(req(t, :post, team(c), attrs(c), csrf: false), 403)["error"] ==
             "invalid_csrf_token"

    assert json_response(req(t, :post, team(c), attrs(c), origin: "https://evil.test"), 403)[
             "error"
           ] == "invalid_origin"

    assert json_response(req(t, :post, team(c), Map.put(attrs(c), :status, "active")), 422)[
             "error"
           ] == "invalid_input"

    foreign = job_fixture()
    assert json_response(req(t, :post, team(c), attrs(foreign)), 403)["error"] == "forbidden"

    assert json_response(req(t, :get, team(c) <> "?shop_id=#{foreign.shop.id}"), 422)["error"] ==
             "invalid_input"

    assert get_resp_header(req(t, :get, team(c)), "cache-control") == ["no-store"]
  end

  test "audit failure rolls back assignment and returns generic persistence failure", c do
    Repo.query!(
      "ALTER TABLE appointment_assignment_audit_events ADD CONSTRAINT test_http_team_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert json_response(req(token(c.owner), :post, team(c), attrs(c)), 503) == %{
             "error" => "operation_unavailable"
           }

    assert Repo.aggregate(JobAssignment, :count) == 0
  end

  test "management classification and ended employment cannot receive jobs; cross-shop overlap is preserved",
       c do
    t = token(c.owner)
    manager = second_detailer(c, %{classification: :shop_manager})

    body = %{
      employee_id: manager.employment.employee_id,
      period_id: manager.employment.id,
      assignment_id: manager.assignment.id
    }

    assert json_response(req(t, :post, team(c), body), 409)["error"] == "ineligible_detailer"
    assert json_response(req(t, :post, team(c), attrs(c)), 201)
    %{shop: other, price: price} = shop_price_fixture(c.price)

    {:ok, a} =
      SchedulerApi.Employment.assign_shop(c.employment, other, %{starts_on: ~D[2026-01-01]})

    {:ok, booking} =
      SchedulerApi.Appointments.create_appointment(other, %{
        SchedulerApi.AppointmentsFixtures.booking_attrs(price)
        | starts_at: DateTime.add(c.booking.starts_at, 3600)
      })

    other_path = base(c) <> "/shops/#{other.id}/appointments/#{booking.id}/team"

    assert json_response(
             req(t, :post, other_path, %{
               employee_id: c.employment.employee_id,
               period_id: c.employment.id,
               assignment_id: a.id
             }),
             409
           )["error"] == "overlap"

    {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    assert json_response(req(t, :post, team(c), attrs(c)), 409)["error"] == "ineligible_detailer"
  end
end
