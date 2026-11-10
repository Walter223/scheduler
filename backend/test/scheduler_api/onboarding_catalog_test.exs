defmodule SchedulerApi.OnboardingCatalogTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.BusinessOnboarding, as: Workflow
  alias SchedulerApi.BusinessOnboarding.Validation
  alias SchedulerApi.Accounts.SessionCredential

  setup do
    shop = shop_fixture()
    user = active_user_fixture()
    grant_fixture(user, shop, :business_owner)
    {_s, raw} = session_fixture(user)
    token = %SessionCredential{value: raw}
    {:ok, d} = Workflow.start(token, shop.business_id)

    locations = [
      %{
        "key" => "one",
        "existing_shop_id" => shop.id,
        "name" => "First",
        "address" => "100 Fictional Way",
        "timezone" => "America/Denver",
        "operating_model" => "in_shop"
      },
      %{
        "key" => "two",
        "name" => "Second",
        "address" => "200 Fictional Way",
        "timezone" => "America/Denver",
        "operating_model" => "both",
        "mobile" => %{
          "service_areas" => ["Denver"],
          "dispatch_source" => "this_location",
          "travel_buffer_minutes" => 30
        }
      }
    ]

    service = %{
      "version" => 2,
      "key" => "exterior",
      "name" => "Custom exterior",
      "description" => "Fictional wash\nand finish",
      "duration_minutes" => 70,
      "status" => "active",
      "delivery_mode" => "in_shop",
      "location_keys" => ["one", "two"],
      "prices" => [
        %{"category_key" => "compact", "price_cents" => 12345},
        %{"category_key" => "van", "price_cents" => 23456}
      ],
      "overrides" => [
        %{
          "location_key" => "two",
          "duration_minutes" => 90,
          "delivery_mode" => "mobile",
          "status" => "planned",
          "prices" => [%{"category_key" => "van", "price_cents" => 34567}]
        }
      ]
    }

    catalog = %{
      "version" => 1,
      "currency" => "USD",
      "vehicle_categories" => [
        %{"key" => "compact", "name" => "City car"},
        %{"key" => "van", "name" => "Adventure van"}
      ]
    }

    %{
      shop: shop,
      user: user,
      token: token,
      d: d,
      service: service,
      catalog: catalog,
      p:
        Map.merge(d["proposal"], %{
          "locations" => locations,
          "catalog" => catalog,
          "services" => [service]
        })
    }
  end

  defp request(d, p, state \\ "locations"),
    do: %{
      "revision" => d["revision"],
      "request_id" => Ecto.UUID.generate(),
      "state" => state,
      "proposal" => p
    }

  test "custom shared pricing, local overrides, retry and resume never change the live catalog",
       c do
    counts =
      for table <- ~w(services vehicle_sizes service_prices appointments),
          into: %{},
          do: {table, Repo.aggregate(table, :count)}

    attrs = request(c.d, c.p)
    assert {:ok, r} = Workflow.update(c.token, c.shop.business_id, attrs)
    assert {:ok, ^r} = Workflow.update(c.token, c.shop.business_id, attrs)
    assert {:ok, ^r} = Workflow.get(c.token, c.shop.business_id)
    assert r["proposal"]["services"] == [c.service]
    assert r["readiness"]["services_configured"]
    refute r["readiness"]["published"]

    assert {:error, :revision_conflict} =
             Workflow.update(c.token, c.shop.business_id, request(c.d, c.p))

    for {table, count} <- counts, do: assert(Repo.aggregate(table, :count) == count)
    assert Repo.aggregate("business_onboarding_events", :count) == 2
  end

  test "deferral saves but cannot advance past Services as complete", c do
    p = %{c.p | "services" => [], "catalog" => %{c.catalog | "vehicle_categories" => []}}
    {:ok, d} = Workflow.update(c.token, c.shop.business_id, request(c.d, p))
    {:ok, d} = Workflow.update(c.token, c.shop.business_id, request(d, p, "employees"))
    {:ok, d} = Workflow.update(c.token, c.shop.business_id, request(d, p, "services_pricing"))
    refute d["readiness"]["services_configured"]

    assert {:error, :incomplete_draft} =
             Workflow.update(c.token, c.shop.business_id, request(d, p, "branding"))

    assert {:ok, r} = Workflow.update(c.token, c.shop.business_id, request(d, c.p, "branding"))
    assert r["readiness"]["services_configured"]
    refute r["readiness"]["published"]
  end

  test "invalid money, durations, status, duplicate names, references and injection fail closed",
       c do
    invalid_services = [
      Map.delete(c.service, "description"),
      Map.put(c.service, "name", " "),
      Map.put(c.service, "duration_minutes", 0),
      Map.put(c.service, "duration_minutes", 1.5),
      Map.put(c.service, "duration_minutes", 1441),
      Map.put(c.service, "status", "published"),
      Map.put(c.service, "delivery_mode", "air"),
      Map.put(c.service, "shop_id", c.shop.id),
      Map.put(c.service, "location_keys", []),
      Map.put(c.service, "location_keys", ["another-tenant"]),
      Map.put(c.service, "prices", []),
      Map.put(c.service, "overrides", [%{"location_key" => "missing", "prices" => []}]),
      Map.put(c.service, "overrides", [
        %{"location_key" => "two", "prices" => [], "duration_minutes" => -1}
      ])
    ]

    invalid_prices =
      for amount <- [0, -1, 123.45, "12.34", nil, 100_000_001],
          do: %{
            c.service
            | "prices" => [
                %{"category_key" => "compact", "price_cents" => amount},
                %{"category_key" => "van", "price_cents" => 1}
              ]
          }

    for s <- invalid_services ++ invalid_prices do
      assert {:error, :invalid_input} =
               Workflow.update(
                 c.token,
                 c.shop.business_id,
                 request(c.d, %{c.p | "services" => [s]})
               )
    end

    for services <- [
          [c.service, %{c.service | "key" => "different", "name" => "CUSTOM EXTERIOR"}],
          [c.service, %{c.service | "name" => "Different"}]
        ] do
      refute Validation.valid?(%{c.p | "services" => services}, c.shop.business_id)
    end

    for categories <- [
          [],
          [%{"key" => "compact", "name" => "Car"}, %{"key" => "van", "name" => "CAR"}],
          [%{"key" => "compact", "name" => "A"}, %{"key" => "compact", "name" => "B"}]
        ] do
      refute Validation.valid?(
               %{c.p | "catalog" => %{c.catalog | "vehicle_categories" => categories}},
               c.shop.business_id
             )
    end

    refute Validation.valid?(
             %{c.p | "catalog" => %{c.catalog | "currency" => "EUR"}},
             c.shop.business_id
           )
  end

  test "legacy services remain readable but require explicit catalog completion", c do
    legacy =
      Map.delete(c.p, "catalog")
      |> Map.put("services", [
        %{"name" => "Legacy", "duration_minutes" => 60, "price_cents" => 12345}
      ])

    assert {:ok, r} = Workflow.update(c.token, c.shop.business_id, request(c.d, legacy))
    refute r["readiness"]["services_configured"]

    refute Validation.valid?(
             %{
               legacy
               | "services" => [
                   %{"name" => "Legacy", "duration_minutes" => 60, "price_cents" => 0}
                 ]
             },
             c.shop.business_id
           )
  end

  test "shop modes and overrides cannot claim unsupported delivery; mobile remains a proposal",
       c do
    for mode <- ["mobile", "both"] do
      refute Validation.valid?(
               %{c.p | "services" => [%{c.service | "delivery_mode" => mode}]},
               c.shop.business_id
             )
    end

    assert Validation.valid?(c.p, c.shop.business_id)

    refute Validation.valid?(
             %{
               c.p
               | "services" => [
                   %{
                     c.service
                     | "overrides" => [
                         %{"location_key" => "one", "prices" => [], "delivery_mode" => "mobile"}
                       ]
                   }
                 ]
             },
             c.shop.business_id
           )

    # Defaults also govern delivery compatibility.
    p =
      put_in(
        c.p,
        ["locations", Access.at(0)],
        Map.delete(hd(c.p["locations"]), "operating_model")
      )

    assert Validation.valid?(
             %{p | "defaults" => %{"operating_model" => "in_shop"}},
             c.shop.business_id
           )
  end

  test "stable keys survive renames/reordering but deleted category/shop references require resolution",
       c do
    p = %{
      c.p
      | "locations" => Enum.reverse(c.p["locations"]),
        "catalog" => %{
          c.catalog
          | "vehicle_categories" => [
              %{"key" => "van", "name" => "Renamed van"},
              %{"key" => "compact", "name" => "Renamed car"}
            ]
        }
    }

    assert Validation.valid?(p, c.shop.business_id)
    refute Validation.valid?(%{p | "locations" => [hd(p["locations"])]}, c.shop.business_id)

    refute Validation.valid?(
             %{
               p
               | "catalog" => %{
                   c.catalog
                   | "vehicle_categories" => [hd(c.catalog["vehicle_categories"])]
                 }
             },
             c.shop.business_id
           )

    duplicate_prices = c.service["prices"] ++ [hd(c.service["prices"])]

    refute Validation.valid?(
             %{p | "services" => [%{c.service | "prices" => duplicate_prices}]},
             c.shop.business_id
           )

    duplicate_overrides = c.service["overrides"] ++ c.service["overrides"]

    refute Validation.valid?(
             %{p | "services" => [%{c.service | "overrides" => duplicate_overrides}]},
             c.shop.business_id
           )
  end

  test "Owner-only and persisted tenant boundaries apply to catalog proposals", c do
    other = other_business_price_fixture().shop
    assert {:error, :forbidden} = Workflow.update(c.token, other.business_id, request(c.d, c.p))
    foreign = put_in(c.p, ["locations", Access.at(0), "existing_shop_id"], other.id)

    assert {:error, :invalid_input} =
             Workflow.update(c.token, c.shop.business_id, request(c.d, foreign))

    for role <- [:business_manager, :shop_manager, :employee] do
      u = active_user_fixture()
      grant_fixture(u, c.shop, role)
      {_s, raw} = session_fixture(u)

      assert {:error, :forbidden} =
               Workflow.update(
                 %SessionCredential{value: raw},
                 c.shop.business_id,
                 request(c.d, c.p)
               )
    end
  end
end
