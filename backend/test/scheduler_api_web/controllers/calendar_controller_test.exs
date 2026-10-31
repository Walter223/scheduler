defmodule SchedulerApiWeb.CalendarControllerTest do
  use SchedulerApiWeb.ConnCase, async: true
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.AdminAccessFixtures
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()

  test "session boundary, no-store projection, selectors and revocation", c do
    date =
      c.booking.starts_at
      |> SchedulerApi.Appointments.Availability.local_datetime()
      |> NaiveDateTime.to_date()
      |> Date.to_iso8601()

    path = "/api/admin/businesses/#{c.business.id}/calendar?date=#{date}"
    assert build_conn() |> get(path) |> json_response(401)
    {s, t} = session_fixture(c.owner)
    conn = build_conn() |> put_req_cookie(BrowserSession.session_name(), t) |> get(path)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert length(json_response(conn, 200)["data"]["appointments"]) == 1

    assert build_conn()
           |> put_req_cookie(BrowserSession.session_name(), t)
           |> get(path <> "&days=90")
           |> json_response(422)

    {:ok, _} = SchedulerApi.Accounts.revoke_session(s, :logout)

    assert build_conn()
           |> put_req_cookie(BrowserSession.session_name(), t)
           |> get(path)
           |> json_response(401)
  end
end
