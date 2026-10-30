defmodule SchedulerApiWeb.EmployeeControllerTest do
  use SchedulerApiWeb.ConnCase, async: true
  import Ecto.Query
  import SchedulerApi.JobAssignmentFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.{Accounts, Employment, Repo}
  alias SchedulerApi.Employment.{HR, Directory}
  alias SchedulerApi.Organizations.{Memberships, Shop}
  alias SchedulerApiWeb.BrowserSession
  setup do: job_fixture()
  defp base(c), do: "/api/admin/businesses/#{c.business.id}"
  defp directory(c), do: base(c) <> "/employees"
  defp profile(c, e), do: directory(c) <> "/#{e.employee_id}"
  defp roster(c, shop), do: base(c) <> "/shops/#{shop.id}/employees"
  defp token(user), do: session_fixture(user) |> elem(1)

  defp request(token, path) do
    conn = build_conn()
    conn = if token, do: put_req_cookie(conn, BrowserSession.session_name(), token), else: conn
    get(conn, path)
  end

  test "all routes require a current browser session and no-store", c do
    routes = [
      directory(c),
      profile(c, c.employment),
      profile(c, c.employment) <> "/periods",
      profile(c, c.employment) <> "/periods/#{c.employment.id}",
      roster(c, c.shop)
    ]

    for path <- routes, credential <- [nil, "invalid"] do
      response = request(credential, path)
      assert json_response(response, 401) == %{"error" => "authentication_required"}
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    for mode <- [:expired, :revoked] do
      opts =
        if mode == :expired,
          do: [now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3600)],
          else: []

      {session, credential} = session_fixture(c.owner, opts)
      if mode == :revoked, do: Accounts.revoke_session(session, :logout)

      assert json_response(request(credential, directory(c)), 401) == %{
               "error" => "authentication_required"
             }

      for path <- routes do
        assert json_response(request(credential, path), 401) == %{
                 "error" => "authentication_required"
               }
      end

      assert {:error, :unauthenticated} =
               Directory.read(session, :directory, "#{c.business.id}", nil, nil, %{})
    end
  end

  test "Owner and Business Manager get allowlisted HR directory profile and history", c do
    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)

    for user <- [c.owner, manager] do
      credential = token(user)
      response = request(credential, directory(c))
      [e] = json_response(response, 200)["employees"]
      assert e["employee_id"] == c.employment.id and e["period_id"] == c.employment.id

      assert Enum.sort(Map.keys(e)) ==
               Enum.sort(
                 ~w(employee_id period_id business_id first_name last_name classification status starts_on ends_on phone email home_address)
               )

      assert json_response(request(credential, profile(c, c.employment)), 200)["employee"] == e

      assert length(
               json_response(request(credential, profile(c, c.employment) <> "/periods"), 200)[
                 "employees"
               ]
             ) == 1

      assert json_response(
               request(credential, profile(c, c.employment) <> "/periods/#{c.employment.id}"),
               200
             )["employee"] == e

      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    grant_fixture(c.owner, c.shop, :business_manager)
    assert length(json_response(request(token(c.owner), directory(c)), 200)["employees"]) == 1
  end

  test "Shop Managers receive only current assigned-shop contacts, never HR history/profile", c do
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)
    other = shop_fixture(%{business_id: c.business.id})
    other_e = employment_fixture(%{}, business: c.business)
    {:ok, _} = Employment.assign_shop(other_e, other, %{starts_on: ~D[2026-01-01]})
    credential = token(sm)
    assert length(json_response(request(credential, roster(c, c.shop)), 200)["employees"]) == 1

    for path <- [
          directory(c),
          profile(c, c.employment),
          profile(c, c.employment) <> "/periods",
          roster(c, other)
        ] do
      assert json_response(request(credential, path), 403) == %{"error" => "forbidden"}
    end

    grant_fixture(sm, other, :employee)
    assert json_response(request(credential, roster(c, other)), 403) == %{"error" => "forbidden"}
    grant_fixture(sm, other, :shop_manager)

    assert hd(json_response(request(credential, roster(c, other)), 200)["employees"])["period_id"] ==
             other_e.id
  end

  test "Employee sessions cannot access HR reads or history, including own or guessed IDs", c do
    credential = token(c.detailer)

    for path <- [
          directory(c),
          profile(c, c.employment),
          profile(c, c.employment) <> "/periods",
          profile(c, c.employment) <> "/periods/#{c.employment.id}",
          roster(c, c.shop)
        ] do
      assert json_response(request(credential, path), 403) == %{"error" => "forbidden"}
    end
  end

  test "distinct Owners and the same Owner with independent grants preserve tenant boundaries",
       c do
    foreign = job_fixture()
    credential = token(c.owner)

    assert json_response(request(credential, directory(foreign)), 403) == %{
             "error" => "forbidden"
           }

    assert json_response(request(token(foreign.owner), directory(c)), 403) == %{
             "error" => "forbidden"
           }

    grant_fixture(c.owner, foreign.shop, :business_owner)

    assert hd(json_response(request(credential, directory(foreign)), 200)["employees"])[
             "period_id"
           ] == foreign.employment.id

    assert hd(json_response(request(credential, directory(c)), 200)["employees"])["period_id"] ==
             c.employment.id

    assert json_response(request(credential, profile(c, foreign.employment)), 403) == %{
             "error" => "forbidden"
           }

    assert json_response(request(credential, roster(c, foreign.shop)), 403) == %{
             "error" => "forbidden"
           }
  end

  test "former employees are retained; rehire returns latest profile and protected period history",
       c do
    credential = token(c.owner)
    {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    assert json_response(request(credential, directory(c)), 200)["employees"] == []

    assert length(
             json_response(request(credential, directory(c) <> "?status=former"), 200)[
               "employees"
             ]
           ) == 1

    {:ok, new} = HR.rehire_employment(c.credential, c.employment, Date.add(Date.utc_today(), 1))
    # Stable-ID route selects latest period, not the original/root ID as period.
    assert json_response(request(credential, profile(c, c.employment)), 200)["employee"][
             "period_id"
           ] == new.id

    assert json_response(request(credential, directory(c) <> "?status=former"), 200)["employees"] ==
             []

    assert length(
             json_response(request(credential, directory(c) <> "?status=all"), 200)["employees"]
           ) == 1

    history =
      json_response(request(credential, profile(c, c.employment) <> "/periods"), 200)["employees"]

    assert Enum.map(history, & &1["period_id"]) == [c.employment.id, new.id]
    refute Enum.any?(history, &Map.has_key?(&1, "home_address"))

    assert json_response(
             request(
               token(c.detailer),
               profile(c, c.employment) <> "/periods/#{c.employment.id}"
             ),
             403
           ) == %{"error" => "forbidden"}

    # Rehire does not restore access; even an explicit new Employee grant cannot read HR history.
    {:ok, _} = Memberships.reactivate(Repo.reload!(c.employee_membership))
    grant_fixture(c.detailer, c.shop, :employee)

    assert json_response(request(token(c.detailer), profile(c, c.employment)), 403) == %{
             "error" => "forbidden"
           }
  end

  test "same stale cookie loses terminated-business HR access but keeps unrelated-business HR access",
       c do
    foreign = job_fixture()
    grant_fixture(c.detailer, c.shop, :business_manager)
    grant_fixture(c.detailer, foreign.shop, :business_manager)
    other = employment_fixture(%{}, business: foreign.business, user: c.detailer)
    credential = token(c.detailer)
    assert json_response(request(credential, directory(c)), 200)
    assert json_response(request(credential, directory(foreign)), 200)
    {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    assert json_response(request(credential, directory(c)), 403) == %{"error" => "forbidden"}

    assert Enum.any?(
             json_response(request(credential, directory(foreign)), 200)["employees"],
             &(&1["period_id"] == other.id)
           )

    assert Repo.reload!(other).status == :active
  end

  test "bounded scope-bound cursors, unknown selectors and malformed IDs cannot bypass authorization",
       c do
    second = employment_fixture(%{}, business: c.business)
    credential = token(c.owner)
    page = json_response(request(credential, directory(c) <> "?limit=1"), 200)
    cursor = page["meta"]["next_cursor"]
    assert page["meta"]["has_more"]

    assert hd(
             json_response(request(credential, directory(c) <> "?limit=1&cursor=#{cursor}"), 200)[
               "employees"
             ]
           )["employee_id"] == second.id

    foreign = job_fixture()
    grant_fixture(c.owner, foreign.shop, :business_owner)

    for path <- [
          directory(foreign) <> "?cursor=#{cursor}",
          directory(c) <> "?status=former&cursor=#{cursor}",
          directory(c) <> "?limit=101",
          directory(c) <> "?cursor=bad",
          directory(c) <> "?status=invalid",
          directory(c) <> "?business_id=#{foreign.business.id}",
          profile(c, c.employment) <> "?user_id=1",
          base(c) <> "/employees/nope"
        ] do
      assert json_response(request(credential, path), 422) == %{"error" => "invalid_options"}
    end

    assert json_response(
             request(credential, base(c) <> "/employees/#{second.id}/periods/#{c.employment.id}"),
             403
           ) == %{"error" => "forbidden"}
  end

  test "current grant, account and archived scope state override stale cookies", c do
    sm = active_user_fixture()
    {member, _} = grant_fixture(sm, c.shop, :shop_manager)
    credential = token(sm)
    assert json_response(request(credential, roster(c, c.shop)), 200)
    {:ok, _} = Memberships.revoke(member)
    assert json_response(request(credential, roster(c, c.shop)), 403) == %{"error" => "forbidden"}
    Repo.update_all(from(s in Shop, where: s.id == ^c.shop.id), set: [status: :archived])

    assert json_response(request(token(c.owner), roster(c, c.shop)), 403) == %{
             "error" => "forbidden"
           }

    owner_token = token(c.owner)
    {:ok, _} = Accounts.set_user_status(c.owner, :suspended)

    assert json_response(request(owner_token, directory(c)), 401) == %{
             "error" => "authentication_required"
           }
  end

  test "stable IDs never alias new period IDs; history pagination stays within the employee", c do
    {:ok, _} = HR.terminate_employment(c.credential, c.employment)
    {:ok, new} = HR.rehire_employment(c.credential, c.employment, Date.add(Date.utc_today(), 1))
    other = employment_fixture(%{}, business: c.business)
    credential = token(c.owner)

    assert json_response(request(credential, directory(c) <> "/#{new.id}"), 403) == %{
             "error" => "forbidden"
           }

    path = profile(c, c.employment) <> "/periods"
    first = json_response(request(credential, path <> "?limit=1"), 200)
    assert hd(first["employees"])["period_id"] == c.employment.id
    cursor = first["meta"]["next_cursor"]
    second = json_response(request(credential, path <> "?limit=1&cursor=#{cursor}"), 200)
    assert Enum.map(second["employees"], & &1["period_id"]) == [new.id]

    assert second["meta"] == %{
             "has_more" => false,
             "next_cursor" => nil,
             "timezone" => "America/Denver"
           }

    assert json_response(
             request(credential, profile(c, other) <> "/periods?cursor=#{cursor}"),
             422
           ) == %{"error" => "invalid_options"}
  end

  test "ended shop assignment excludes current shop contact but not active business employee",
       c do
    sm = active_user_fixture()
    grant_fixture(sm, c.shop, :shop_manager)

    {:ok, _} =
      SchedulerApi.Employment.WorkSchedules.cancel_shift(
        c.credential,
        %SchedulerApi.Employment.WorkShift{id: c.shift.id}
      )

    {:ok, _} = HR.end_shop_assignment(c.credential, c.assignment, Date.utc_today())
    assert json_response(request(token(sm), roster(c, c.shop)), 200)["employees"] == []
    assert length(json_response(request(token(c.owner), directory(c)), 200)["employees"]) == 1
  end

  test "pending deactivated and unverified accounts fail authentication; archived business denies HR",
       c do
    for mode <- [:pending, :deactivated, :unverified] do
      user = active_user_fixture()
      grant_fixture(user, c.shop, :business_owner)
      credential = token(user)

      if mode == :unverified,
        do: Repo.update!(Ecto.Changeset.change(user, email_verified: false)),
        else: Accounts.set_user_status(user, mode)

      assert json_response(request(credential, directory(c)), 401) == %{
               "error" => "authentication_required"
             }
    end

    assert json_response(request(token(active_user_fixture()), directory(c)), 403) == %{
             "error" => "forbidden"
           }

    credential = token(c.owner)
    Repo.update!(Ecto.Changeset.change(c.business, status: :archived))

    for path <- [
          directory(c),
          profile(c, c.employment),
          profile(c, c.employment) <> "/periods",
          roster(c, c.shop)
        ] do
      assert json_response(request(credential, path), 403) == %{"error" => "forbidden"}
    end
  end
end
