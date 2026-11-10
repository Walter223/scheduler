defmodule SchedulerApi.OnboardingStaffTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.ShopsFixtures
  alias SchedulerApi.BusinessOnboarding, as: Workflow
  alias SchedulerApi.Accounts.SessionCredential

  setup do
    shop = shop_fixture()
    user = active_user_fixture()
    grant_fixture(user, shop, :business_owner)
    {_s, t} = session_fixture(user)
    credential = %SessionCredential{value: t}
    {:ok, d} = Workflow.start(credential, shop.business_id)

    locations = [
      %{
        "key" => "first",
        "existing_shop_id" => shop.id,
        "name" => "First",
        "address" => "100 Fictional Way",
        "timezone" => "America/Denver",
        "operating_model" => "in_shop"
      },
      %{
        "key" => "second",
        "name" => "Second",
        "address" => "200 Fictional Way",
        "timezone" => "America/Denver",
        "operating_model" => "in_shop"
      }
    ]

    staff = %{
      "version" => 2,
      "key" => "person-one",
      "name" => "Fictional Person",
      "email" => "staff@example.invalid",
      "classification" => "detailer",
      "location_keys" => ["first", "second"],
      "responsibilities" => %{
        "business_management" => false,
        "shop_management_keys" => ["second"]
      },
      "access_roles" => [
        %{"role" => "employee", "location_keys" => ["first", "second"]},
        %{"role" => "shop_manager", "location_keys" => ["second"]}
      ]
    }

    %{
      shop: shop,
      user: user,
      credential: credential,
      d: d,
      proposal: Map.merge(d["proposal"], %{"locations" => locations, "employees" => [staff]}),
      staff: staff
    }
  end

  defp request(c, p),
    do: %{
      "revision" => c.d["revision"],
      "request_id" => Ecto.UUID.generate(),
      "state" => "locations",
      "proposal" => p
    }

  test "multiple assignments, distinct classification and roles save, retry and resume without domain writes",
       c do
    attrs = request(c, c.proposal)
    assert {:ok, r} = Workflow.update(c.credential, c.shop.business_id, attrs)
    assert {:ok, ^r} = Workflow.update(c.credential, c.shop.business_id, attrs)
    assert {:ok, ^r} = Workflow.get(c.credential, c.shop.business_id)
    assert Repo.aggregate(SchedulerApi.Organizations.RoleAssignment, :count) == 1
    assert Repo.aggregate(SchedulerApi.Employment.EmploymentRecord, :count) == 0
    assert Repo.aggregate(SchedulerApi.Organizations.BusinessMembership, :count) == 1
    assert r["proposal"]["employees"] == [c.staff]

    assert {:error, :revision_conflict} =
             Workflow.update(c.credential, c.shop.business_id, request(c, c.proposal))
  end

  test "solo and business managers without operational shop scope are supported", c do
    for employees <- [
          [],
          [
            %{
              c.staff
              | "location_keys" => [],
                "classification" => "business_manager",
                "responsibilities" => %{
                  "business_management" => true,
                  "shop_management_keys" => []
                },
                "access_roles" => [%{"role" => "business_manager", "location_keys" => []}]
            }
          ]
        ] do
      p = Map.put(c.proposal, "employees", employees)
      assert SchedulerApi.BusinessOnboarding.Validation.valid?(p, c.shop.business_id)
    end
  end

  test "rejects malformed, duplicate, credential and privilege injection fields", c do
    invalid = [
      Map.delete(c.staff, "email"),
      Map.put(c.staff, "email", "bad-email"),
      Map.put(c.staff, "email", "staff@bad..example"),
      Map.put(c.staff, "email", "staff@-bad.example"),
      Map.put(c.staff, "email", "a..b@example.invalid"),
      Map.put(c.staff, "name", " "),
      Map.put(c.staff, "classification", "administrator"),
      Map.put(c.staff, "password", "forbidden"),
      Map.put(c.staff, "version", 1),
      Map.put(c.staff, "location_keys", ["other-business"]),
      Map.put(c.staff, "access_roles", [%{"role" => "business_owner", "location_keys" => []}]),
      Map.put(c.staff, "access_roles", [%{"role" => "shop_manager", "location_keys" => []}]),
      Map.put(c.staff, "access_roles", [
        %{"role" => "business_manager", "location_keys" => ["first"]}
      ])
    ]

    for staff <- invalid do
      assert {:error, :invalid_input} =
               Workflow.update(
                 c.credential,
                 c.shop.business_id,
                 request(c, Map.put(c.proposal, "employees", [staff]))
               )
    end

    for other <- [
          Map.put(c.staff, "key", "another"),
          %{c.staff | "key" => "another", "email" => "STAFF@example.invalid"}
        ] do
      assert {:error, :invalid_input} =
               Workflow.update(
                 c.credential,
                 c.shop.business_id,
                 request(c, Map.put(c.proposal, "employees", [c.staff, other]))
               )
    end
  end

  test "renaming/reordering retains references; removing assigned shops must be resolved", c do
    p = Map.update!(c.proposal, "locations", fn [a, b] -> [b, Map.put(a, "name", "Renamed")] end)
    assert {:ok, _} = Workflow.update(c.credential, c.shop.business_id, request(c, p))

    refute SchedulerApi.BusinessOnboarding.Validation.valid?(
             Map.put(p, "locations", [hd(p["locations"])]),
             c.shop.business_id
           )

    p = Map.put(p, "locations", [])
    refute SchedulerApi.BusinessOnboarding.Validation.valid?(p, c.shop.business_id)

    assert SchedulerApi.BusinessOnboarding.Validation.valid?(
             Map.put(p, "employees", []),
             c.shop.business_id
           )
  end

  test "cross-business and Manager writes denied; revocation invalidates session authorization",
       c do
    other = other_business_price_fixture().shop

    assert {:error, :forbidden} =
             Workflow.update(c.credential, other.business_id, request(c, c.proposal))

    manager = active_user_fixture()
    grant_fixture(manager, c.shop, :business_manager)
    {_s, t} = session_fixture(manager)

    assert {:error, :forbidden} =
             Workflow.update(
               %SessionCredential{value: t},
               c.shop.business_id,
               request(c, c.proposal)
             )

    {:ok, _} = SchedulerApi.Accounts.set_user_status(c.user, :suspended)
    assert {:error, :invalid_session} = Workflow.get(c.credential, c.shop.business_id)
  end
end
