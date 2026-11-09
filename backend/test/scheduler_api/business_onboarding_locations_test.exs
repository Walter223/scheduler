defmodule SchedulerApi.BusinessOnboardingLocationsTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.BusinessOnboarding, as: Workflow
  alias SchedulerApi.Accounts.SessionCredential
  alias SchedulerApi.Organizations.Shop

  setup do
    shop = shop_fixture()
    owner = active_user_fixture()
    grant_fixture(owner, shop, :business_owner)
    {_s, t} = session_fixture(owner)
    token = %SessionCredential{value: t}
    {:ok, d} = Workflow.start(token, shop.business_id)

    p = %{
      d["proposal"]
      | "defaults" => %{
          "timezone" => "America/Denver",
          "operating_model" => "both",
          "mobile" => %{
            "dispatch_source" => "location_key",
            "dispatch_location_key" => "first",
            "service_areas" => ["Denver"],
            "travel_buffer_minutes" => 30
          }
        },
        "locations" => [
          %{
            "key" => "first",
            "existing_shop_id" => shop.id,
            "name" => "Existing headquarters",
            "address" => "100 Fictional Way",
            "operating_model" => "in_shop"
          },
          %{
            "key" => "second",
            "name" => "Mobile base",
            "address" => "200 Fictional Way",
            "timezone" => "America/New_York",
            "mobile" => %{"travel_buffer_minutes" => 45}
          }
        ]
    }

    %{shop: shop, token: token, d: d, p: p}
  end

  defp request(c, p),
    do: %{
      "revision" => c.d["revision"],
      "request_id" => Ecto.UUID.generate(),
      "state" => "locations",
      "proposal" => p
    }

  test "multiple locations resume with inherited defaults and overrides without duplicating initial shop",
       c do
    before = Repo.all(Shop)
    req = request(c, c.p)
    assert {:ok, r} = Workflow.update(c.token, c.shop.business_id, req)
    assert {:ok, ^r} = Workflow.update(c.token, c.shop.business_id, req)
    assert {:ok, ^r} = Workflow.get(c.token, c.shop.business_id)
    [first, second] = r["effective_locations"]
    assert first["existing_shop_id"] == c.shop.id
    assert first["operating_model"] == "in_shop"
    assert second["timezone"] == "America/New_York"
    assert second["mobile"]["travel_buffer_minutes"] == 45
    assert second["mobile"]["service_areas"] == ["Denver"]
    assert second["mobile"]["dispatch_location_key"] == "first"
    assert r["proposal"]["employees"] == []
    refute r["readiness"]["published"]
    assert Repo.all(Shop) == before
  end

  test "bad zones, addresses, dispatch references, duplicate identities and travel bounds fail",
       c do
    bad = [
      put_in(c.p, ["locations", Access.at(1), "timezone"], "Invalid/Zone"),
      put_in(c.p, ["locations", Access.at(1), "address"], "\n"),
      put_in(c.p, ["locations", Access.at(1), "operating_model"], "teleport"),
      put_in(c.p, ["defaults", "mobile", "dispatch_location_key"], "foreign"),
      put_in(c.p, ["locations", Access.at(1), "mobile", "travel_buffer_minutes"], -1),
      put_in(c.p, ["locations", Access.at(1), "mobile", "travel_buffer_minutes"], 1.5),
      put_in(c.p, ["locations", Access.at(1), "key"], "first"),
      put_in(c.p, ["locations", Access.at(1), "existing_shop_id"], c.shop.id),
      put_in(c.p, ["locations", Access.at(1), "password"], "forbidden")
    ]

    for proposal <- bad,
        do:
          assert(
            {:error, :invalid_input} =
              Workflow.update(c.token, c.shop.business_id, request(c, proposal))
          )

    assert {:ok, r} = Workflow.get(c.token, c.shop.business_id)
    assert r["revision"] == 0
  end

  test "shop references are tenant-owned and unauthorized roles cannot access mobile drafts", c do
    other = other_business_price_fixture().shop
    proposal = put_in(c.p, ["locations", Access.at(0), "existing_shop_id"], other.id)

    assert {:error, :invalid_input} =
             Workflow.update(c.token, c.shop.business_id, request(c, proposal))

    assert {:error, :forbidden} = Workflow.get(c.token, other.business_id)
    user = active_user_fixture()
    grant_fixture(user, c.shop, :shop_manager)
    {_s, t} = session_fixture(user)

    assert {:error, :forbidden} =
             Workflow.update(%SessionCredential{value: t}, c.shop.business_id, request(c, c.p))
  end

  test "partial drafts save but cannot leave Locations until address/mobile setup is reviewed",
       c do
    proposal =
      put_in(
        c.p,
        ["locations", Access.at(1)],
        Map.delete(Enum.at(c.p["locations"], 1), "address")
      )

    {:ok, r} = Workflow.update(c.token, c.shop.business_id, request(c, proposal))

    attrs = %{
      "revision" => r["revision"],
      "request_id" => Ecto.UUID.generate(),
      "state" => "employees",
      "proposal" => proposal
    }

    assert {:error, :incomplete_draft} = Workflow.update(c.token, c.shop.business_id, attrs)

    assert {:ok, _} =
             Workflow.update(c.token, c.shop.business_id, Map.put(attrs, "proposal", c.p))
  end

  test "later-step edits cannot bypass location completeness before progressing", c do
    {:ok, locations} = Workflow.update(c.token, c.shop.business_id, request(c, c.p))

    step = fn current, state, proposal ->
      %{
        "revision" => current["revision"],
        "request_id" => Ecto.UUID.generate(),
        "state" => state,
        "proposal" => proposal
      }
    end

    {:ok, employees} =
      Workflow.update(c.token, c.shop.business_id, step.(locations, "employees", c.p))

    partial =
      put_in(
        c.p,
        ["locations", Access.at(1)],
        Map.delete(Enum.at(c.p["locations"], 1), "address")
      )

    # Interrupted/partial edits may be saved; progression must revalidate them.
    {:ok, saved} =
      Workflow.update(c.token, c.shop.business_id, step.(employees, "employees", partial))

    assert {:error, :incomplete_draft} =
             Workflow.update(
               c.token,
               c.shop.business_id,
               step.(saved, "services_pricing", partial)
             )

    assert {:ok, _} =
             Workflow.update(c.token, c.shop.business_id, step.(saved, "services_pricing", c.p))
  end
end
