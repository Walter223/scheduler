defmodule SchedulerApiWeb.AdminAppointmentSecurityTest do
  use SchedulerApiWeb.ConnCase, async: true

  alias SchedulerApi.{Accounts, Appointments, Organizations, Repo}
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApiWeb.BrowserSession
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.AppointmentsFixtures
  import SchedulerApi.CatalogFixtures
  import SchedulerApi.ShopsFixtures

  @path "/api/admin/appointments"

  setup do
    price = service_price_fixture()
    %{price: price, shop: Organizations.default_shop!(), user: active_user_fixture()}
  end

  test "missing, malformed and unknown credentials return private, generic 401", %{conn: conn} do
    for token <- [
          nil,
          "invalid",
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        ] do
      request =
        if token, do: put_req_cookie(conn, BrowserSession.session_name(), token), else: conn

      response = get(request, @path)
      assert json_response(response, 401) == %{"error" => "authentication_required"}
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "expired and revoked sessions are rejected, including direct context reuse", %{
    user: user,
    shop: shop
  } do
    grant_fixture(user, shop, :business_owner)

    for change <- [:idle, :absolute, :revoked] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      opts =
        case change do
          :idle -> [now: DateTime.add(now, -3600)]
          :absolute -> [now: DateTime.add(now, -9 * 3600)]
          :revoked -> []
        end

      {session, token} = session_fixture(user, opts)
      if change == :revoked, do: Accounts.revoke_session(session, :logout)
      assert request(token) |> json_response(401) == %{"error" => "authentication_required"}

      assert {:error, :unauthenticated} =
               Appointments.list_authorized_upcoming_appointments(session)
    end
  end

  test "Owner sees every active shop in own business, never another business", context do
    %{user: user, shop: shop, price: price} = context
    grant_fixture(user, shop, :business_owner)
    other = shop_price_fixture(price)
    foreign = other_business_price_fixture()
    first = booking(price, 0)
    second = booking(other.price, 0)
    booking(foreign.price, 0)
    {session, token} = session_fixture(user)
    response = request(token)
    assert ids(json_response(response, 200)) == Enum.sort([first.id, second.id])
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert {:ok, page} = Appointments.list_authorized_upcoming_appointments(session)
    assert Enum.map(page.appointments, & &1.id) == Enum.sort([first.id, second.id])
    assert Enum.all?(page.appointments, &Ecto.assoc_loaded?(&1.service_price.service))
  end

  test "Shop Manager sees only assigned shops; unrelated roles cannot supply extra scope", %{
    user: user,
    shop: shop,
    price: price
  } do
    grant_fixture(user, shop, :shop_manager)
    other = shop_price_fixture(price)
    foreign = other_business_price_fixture()
    grant_fixture(user, other.shop, :employee)
    grant_fixture(user, foreign.shop, :business_manager)
    visible = booking(price, 0)
    booking(other.price, 0)
    booking(foreign.price, 0)
    {_, token} = session_fixture(user)
    assert ids(request(token) |> json_response(200)) == [visible.id]
  end

  test "Business Manager, Employee and identity without grants are forbidden", %{shop: shop} do
    for role <- [:business_manager, :employee, nil] do
      user = active_user_fixture()
      if role, do: grant_fixture(user, shop, role)
      {_, token} = session_fixture(user)
      response = request(token)
      assert json_response(response, 403) == %{"error" => "forbidden"}
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "current pending, suspended, deactivated and unverified accounts invalidate sessions", %{
    shop: shop
  } do
    for status <- [:pending, :suspended, :deactivated, :unverified] do
      user = active_user_fixture()
      grant_fixture(user, shop, :business_owner)
      {session, token} = session_fixture(user)

      if status == :unverified do
        Repo.update!(Ecto.Changeset.change(user, email_verified: false))
      else
        assert {:ok, _} = Accounts.set_user_status(user, status)
      end

      assert request(token) |> json_response(401) == %{"error" => "authentication_required"}

      assert {:error, :unauthenticated} =
               Appointments.list_authorized_upcoming_appointments(session)
    end
  end

  test "revoked membership and grant take effect on the next read; reactivation restores no grant",
       %{user: user, shop: shop} do
    {membership, grant} = grant_fixture(user, shop, :shop_manager)
    {session, token} = session_fixture(user)
    assert request(token) |> json_response(200)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update!(
      Ecto.Changeset.change(grant, status: :revoked, revoked_at: now, revocation_reason: :manual)
    )

    assert request(token) |> json_response(403)
    assert {:error, :forbidden} = Appointments.list_authorized_upcoming_appointments(session)
    {_, replacement} = grant_fixture(user, shop, :shop_manager)
    assert request(token) |> json_response(200)
    assert {:ok, membership} = SchedulerApi.Organizations.Memberships.revoke(membership)
    assert Repo.reload!(replacement).status == :revoked
    assert request(token) |> json_response(403)
    assert {:ok, _} = SchedulerApi.Organizations.Memberships.reactivate(membership)

    assert request(token) |> json_response(403)
  end

  test "a revoked membership alone denies even a still-active grant", %{user: user, shop: shop} do
    {membership, _} = grant_fixture(user, shop, :business_owner)
    {_, token} = session_fixture(user)

    Repo.update!(
      Ecto.Changeset.change(membership,
        status: :revoked,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        revocation_reason: :manual
      )
    )

    assert request(token) |> json_response(403)
  end

  test "archived business or shop cannot authorize a read", %{user: user, shop: shop} do
    grant_fixture(user, shop, :business_owner)
    {_, token} = session_fixture(user)
    Repo.update!(Ecto.Changeset.change(shop, status: :archived))
    assert request(token) |> json_response(403)
    Repo.update!(Ecto.Changeset.change(shop, status: :active))
    business = Repo.get!(SchedulerApi.Organizations.Business, shop.business_id)
    Repo.update!(Ecto.Changeset.change(business, status: :archived))
    assert request(token) |> json_response(403)
  end

  test "client ownership selectors never establish access; spoofed session references fail", %{
    user: user,
    shop: shop
  } do
    grant_fixture(user, shop, :business_owner)
    {session, token} = session_fixture(user)

    for key <- ["business_id", "shop_id", "user_id"] do
      assert request(token, %{key => shop.id}) |> json_response(403) == %{"error" => "forbidden"}
    end

    other = active_user_fixture()

    assert {:error, :unauthenticated} =
             Appointments.list_authorized_upcoming_appointments(%{session | user_id: other.id})

    assert {:error, :unauthenticated} =
             Appointments.list_authorized_upcoming_appointments(%{session | id: -1})
  end

  test "unauthorized rows do not influence has_more or generated cursors", %{
    user: user,
    shop: shop,
    price: price
  } do
    grant_fixture(user, shop, :shop_manager)
    other = shop_price_fixture(price)
    first = booking(price, 0)
    foreign = booking(other.price, 1)
    second = booking(price, 2)
    booking(other.price, 3)
    {_, token} = session_fixture(user)
    page = request(token, %{limit: 1}) |> json_response(200)
    assert ids(page) == [first.id]
    assert page["meta"]["has_more"]
    {:ok, cursor_json} = Base.url_decode64(page["meta"]["next_cursor"], padding: false)
    assert [1, _, id] = Jason.decode!(cursor_json)
    assert id == first.id
    final = request(token, %{limit: 1, cursor: page["meta"]["next_cursor"]}) |> json_response(200)
    assert ids(final) == [second.id]

    assert final["meta"] == %{
             "timezone" => "America/Denver",
             "has_more" => false,
             "next_cursor" => nil
           }

    forged_cursor =
      Jason.encode!([1, DateTime.to_iso8601(foreign.starts_at), foreign.id])
      |> Base.url_encode64(padding: false)

    assert ids(request(token, %{cursor: forged_cursor}) |> json_response(200)) == [second.id]
  end

  test "independent assigned shops are combined without duplicate rows or archived-shop leakage",
       %{user: user, shop: shop, price: price} do
    grant_fixture(user, shop, :business_owner)
    grant_fixture(user, shop, :shop_manager)
    other = other_business_price_fixture()
    grant_fixture(user, other.shop, :shop_manager)
    archived = shop_price_fixture(price)
    Repo.update!(Ecto.Changeset.change(archived.shop, status: :archived))
    first = booking(price, 0)
    second = booking(other.price, 1)
    booking(archived.price, 2)
    {session, token} = session_fixture(user)
    assert ids(request(token) |> json_response(200)) == [first.id, second.id]
    assert {:ok, page} = Appointments.list_authorized_upcoming_appointments(session, limit: 1)
    assert Enum.map(page.appointments, & &1.id) == [first.id]
    assert page.has_more

    assert {:ok, final} =
             Appointments.list_authorized_upcoming_appointments(session,
               limit: 1,
               cursor: page.next_cursor
             )

    assert Enum.map(final.appointments, & &1.id) == [second.id]
    refute final.has_more
  end

  test "private list bypasses development request capture and never logs cookies", %{
    user: user,
    shop: shop
  } do
    grant_fixture(user, shop, :shop_manager)
    {_, token} = session_fixture(user)

    output =
      ExUnit.CaptureLog.capture_log(fn ->
        assert request(token, %{request_logger: "true"}) |> json_response(200)
      end)

    refute output =~ token
  end

  defp request(token, params \\ %{}) do
    build_conn() |> put_req_cookie(BrowserSession.session_name(), token) |> get(@path, params)
  end

  defp ids(body), do: Enum.map(body["appointments"], & &1["id"])

  defp booking(price, hours) do
    start =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(86_400 + hours * 7200)

    %Appointment{
      business_id: price.business_id,
      shop_id: price.shop_id,
      price_cents: price.price_cents,
      duration_minutes: price.duration_minutes
    }
    |> Appointment.changeset(Map.put(booking_attrs(price), :starts_at, start))
    |> Repo.insert!()
  end
end
