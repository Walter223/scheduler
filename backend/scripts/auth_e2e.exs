# Explicit, isolated real-provider fixture runner. Never loaded by the application.
unless Mix.env() == :test and
         Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)[:database] ==
           "scheduler_api_test_auth_e2e" do
  raise "Auth E2E requires MIX_ENV=test and MIX_TEST_PARTITION=_auth_e2e"
end

[command] = System.argv()
fixture = System.fetch_env!("BFF_E2E_FIXTURE") |> File.read!() |> Jason.decode!()

issuer = fixture["issuer"] || "http://auth.magnum.test:8080/realms/magnum"
unless issuer in ["http://auth.magnum.test:8080/realms/magnum", "http://auth.magnum.test:8080/realms/" <> fixture["run_id"]], do: raise("Invalid owned issuer")

unless Regex.match?(~r/^magnum-bff-e2e-[0-9a-f]{32}$/, fixture["run_id"]) and
         Enum.all?(fixture["users"], &String.starts_with?(&1["username"], fixture["run_id"])),
       do: raise("Invalid owned auth fixture")

if command == "server" do
  # Fixed alternate origin, only after the test DB/run-ownership guards above.
  # Production/development constructors remain unchanged; the real protocol still
  # verifies this exact per-run audience, issuer, callback, nonce and PKCE.
  client_id = System.fetch_env!("BFF_E2E_CLIENT_ID")
  unless client_id == fixture["run_id"], do: raise("Invalid owned test client")

  provider = %SchedulerApi.Authentication.Config{
    issuer: issuer,
    callback_url: "http://localhost:5174/auth/callback",
    client_id: client_id,
    client_secret: System.fetch_env!("MAGNUM_WEB_CLIENT_SECRET"),
    local_http: true
  }

  Application.put_env(:scheduler_api, :oidc, provider)

  Application.put_env(:scheduler_api, :browser_auth, %{
    origin: "http://localhost:5174",
    secure: false
  })
end

endpoint = SchedulerApiWeb.Endpoint
config = Application.fetch_env!(:scheduler_api, endpoint)

Application.put_env(
  :scheduler_api,
  endpoint,
  Keyword.merge(config, server: command == "server", http: [ip: {127, 0, 0, 1}, port: 4002])
)

{:ok, _} = Application.ensure_all_started(:scheduler_api)
Ecto.Adapters.SQL.Sandbox.mode(SchedulerApi.Repo, :auto)
Logger.configure(level: :warning)

import Ecto.Query
alias SchedulerApi.{Accounts, Repo}
alias SchedulerApi.Accounts.{User, VerifiedIdentity, WebSession}
alias SchedulerApi.Authentication.LoginTransaction

case command do
  "seed" ->
    # Never overwrite a database containing other identities or login attempts.
    unless Enum.all?([User, WebSession, LoginTransaction], &(Repo.aggregate(&1, :count) == 0)),
      do: raise("Auth E2E database has existing account data; refusing fixture setup")

    Repo.transaction(fn ->
      businesses =
        for suffix <- ["a", "b"] do
          Repo.insert!(%SchedulerApi.Organizations.Business{
            name: "Acceptance " <> suffix,
            slug: fixture["run_id"] <> "-" <> suffix
          })
        end

      [a, b] = businesses

      shops =
        for business <- businesses, n <- 1..2 do
          Repo.insert!(%SchedulerApi.Organizations.Shop{
            business_id: business.id,
            name: business.name <> " shop #{n}",
            slug: "shop-#{n}",
            timezone: "America/Denver"
          })
        end

      for identity <- fixture["users"], identity["kind"] not in ["pending", "registration"] do
        {:ok, user} =
          Accounts.sync_verified_identity(%VerifiedIdentity{
            issuer: issuer,
            subject: identity["subject"],
            email: identity["email"],
            email_verified: true,
            first_name: "E2E",
            last_name: identity["kind"]
          })

        {:ok, user} = Accounts.set_user_status(user, :active)

        roles =
          case identity["kind"] do
            "owner" -> [{a, :business_owner}]
            "manager" -> [{a, :business_manager}]
            "shop_manager" -> [{a, :shop_manager}]
            "employee" -> [{a, :employee}]
            "mixed" -> [{a, :business_owner}, {b, :business_manager}]
            "multi_owner" -> [{a, :business_owner}, {b, :business_owner}]
            _ -> []
          end

        for {business, role} <- roles do
          m =
            Repo.insert!(%SchedulerApi.Organizations.BusinessMembership{
              user_id: user.id,
              business_id: business.id
            })

          scopes =
            if role in [:employee, :shop_manager],
              do: Enum.filter(shops, &(&1.business_id == business.id)),
              else: [nil]

          for shop <- scopes do
            Repo.insert!(%SchedulerApi.Organizations.RoleAssignment{
              membership_id: m.id,
              business_id: business.id,
              role: role,
              shop_id: shop && shop.id
            })
          end

          if identity["kind"] == "employee" do
            # Classification alone confers no management permission.
            {:ok, _} =
              SchedulerApi.Employment.create_employment(
                business,
                %{
                  first_name: "E2E",
                  last_name: "Classification",
                  classification: :business_owner,
                  starts_on: ~D[2026-01-01]
                },
                user: user
              )
          end
        end
      end

      # Today's operational read-model fixtures, owned entirely by this run.
      shop = hd(shops)

      service =
        Repo.insert!(%SchedulerApi.Catalog.Service{
          business_id: a.id,
          name: "Acceptance service",
          description: "Isolated dashboard fixture"
        })

      size =
        Repo.insert!(%SchedulerApi.Catalog.VehicleSize{
          business_id: a.id,
          name: "Fixture",
          sort_order: 1
        })

      price =
        Repo.insert!(%SchedulerApi.Catalog.ServicePrice{
          business_id: a.id,
          shop_id: shop.id,
          service_id: service.id,
          vehicle_size_id: size.id,
          price_cents: 5000,
          duration_minutes: 60
        })

      %{rows: [[starts]]} =
        Repo.query!(
          "SELECT ((CURRENT_TIMESTAMP AT TIME ZONE 'America/Denver')::date + time '09:00') AT TIME ZONE 'America/Denver'",
          [],
          log: false
        )

      starts = DateTime.truncate(starts, :second)

      attrs = %SchedulerApi.Appointments.Appointment{
        business_id: a.id,
        shop_id: shop.id,
        service_price_id: price.id,
        starts_at: starts,
        duration_minutes: 60,
        price_cents: 5000,
        customer_first_name: "Fixture",
        customer_last_name: "Customer",
        customer_email: "fixture@example.invalid",
        customer_phone: "303-555-0100",
        vehicle_make: "Test",
        vehicle_model: "Vehicle"
      }

      appointment = Repo.insert!(attrs)
      Repo.insert!(%{attrs | starts_at: DateTime.add(starts, 10800), status: :cancelled})

      {:ok, employee} =
        SchedulerApi.Employment.create_employment(
          a,
          %{
            first_name: "Fixture",
            last_name: "Detailer",
            classification: :detailer,
            starts_on: ~D[2026-01-01]
          }
        )

      {:ok, assignment} =
        SchedulerApi.Employment.assign_shop(employee, shop, %{starts_on: ~D[2026-01-01]})

      shift =
        Repo.insert!(%SchedulerApi.Employment.WorkShift{
          employment_id: employee.id,
          assignment_id: assignment.id,
          business_id: a.id,
          shop_id: shop.id,
          timezone: shop.timezone,
          starts_at: starts,
          ends_at: DateTime.add(starts, 28800)
        })

      Repo.insert!(%SchedulerApi.Appointments.JobAssignment{
        appointment_id: appointment.id,
        employment_id: employee.id,
        assignment_id: assignment.id,
        work_shift_id: shift.id,
        business_id: a.id,
        shop_id: shop.id,
        starts_at: starts,
        ends_at: DateTime.add(starts, 5400),
        is_lead: true
      })

      # Retained historical fixture and a separately authorized rehire period.
      actor_identity = Enum.find(fixture["users"], &(&1["kind"] == "owner"))
      actor = Repo.get_by!(User, keycloak_subject: actor_identity["subject"])
      {:ok, actor_session, credential} = Accounts.create_session(actor)

      try do
        {:ok, former} =
          SchedulerApi.Employment.create_employment(
            a,
            %{
              first_name: "Former",
              last_name: "Fixture",
              classification: :detailer,
              starts_on: ~D[2025-01-01],
              home_address: "Prior fixture address"
            }
          )

        {:ok, former} = SchedulerApi.Employment.end_employment(former, ~D[2025-12-31])

        Repo.insert!(%SchedulerApi.Employment.OffboardingAudit{
          business_id: a.id,
          employment_id: former.id,
          actor_user_id: actor.id,
          ended_on: ~D[2025-12-31],
          jobs_removed: 0,
          shifts_cancelled: 0,
          assignments_ended: 0,
          occurred_at: ~U[2025-12-31 19:00:00Z]
        })

        {:ok, returning} =
          SchedulerApi.Employment.create_employment(
            a,
            %{
              first_name: "Returning",
              last_name: "Fixture",
              classification: :detailer,
              starts_on: ~D[2025-01-01],
              home_address: "Historical fixture address"
            }
          )

        {:ok, _} =
          SchedulerApi.Employment.HR.update_contact(credential, returning, %{
            home_address: "Historical fixture address"
          })

        {:ok, returning} = SchedulerApi.Employment.end_employment(returning, ~D[2025-12-31])

        Repo.insert!(%SchedulerApi.Employment.OffboardingAudit{
          business_id: a.id,
          employment_id: returning.id,
          actor_user_id: actor.id,
          ended_on: ~D[2025-12-31],
          jobs_removed: 0,
          shifts_cancelled: 0,
          assignments_ended: 0,
          occurred_at: ~U[2025-12-31 19:00:00Z]
        })

        {:ok, new} =
          SchedulerApi.Employment.HR.rehire_employment(credential, returning, ~D[2026-01-01])

        {:ok, _} =
          SchedulerApi.Employment.assign_shop(
            Repo.get!(SchedulerApi.Employment.EmploymentRecord, new.id),
            shop,
            %{starts_on: ~D[2026-01-01]}
          )

        second_shop = Enum.find(shops, &(&1.business_id == a.id and &1.id != shop.id))

        {:ok, _} =
          SchedulerApi.Employment.assign_shop(
            Repo.get!(SchedulerApi.Employment.EmploymentRecord, new.id),
            second_shop,
            %{starts_on: ~D[2026-01-01]}
          )
      after
        {:ok, _} = Accounts.revoke_session(actor_session, :logout)
      end
    end)

    IO.puts("AUTH_E2E_SEEDED")

  action when action in ["suspend_signup_owner", "restore_signup_owner"] ->
    identity = Enum.find(fixture["users"], &(&1["kind"] == "owner"))
    user = Repo.get_by!(User, keycloak_subject: identity["subject"])
    {:ok, _} = Accounts.set_user_status(user, if(action == "suspend_signup_owner", do: :suspended, else: :active))
    IO.puts("OWNED_SIGNUP_STATE_CHANGED")

  "verify" ->
    subjects = Enum.map(fixture["users"], & &1["subject"])
    users = Repo.all(from u in User, where: u.keycloak_subject in ^subjects)

    signup_audits = Repo.all(from e in SchedulerApi.Authorization.AuditEvent,
      where: e.source == :self_service_signup and e.target_user_id in ^Enum.map(users, & &1.id))
    expected = if signup_audits == [], do: List.duplicate(:active, 7) ++ [:pending], else: List.duplicate(:active, length(fixture["users"]))
    unless Enum.sort(Enum.map(users, & &1.status)) == expected,
      do: raise("Expected precise account lifecycle outcomes")
    if signup_audits != [] do
      unless length(signup_audits) == 3 and Enum.count(signup_audits, & &1.activated_pending_account) == 2,
        do: raise("Expected one pending and one active signup audit")
    end

    for audit <- signup_audits do
      shop = Repo.get!(SchedulerApi.Organizations.Shop, audit.shop_id)
      unless shop.business_id == audit.business_id, do: raise("Signup shop ownership mismatch")
      member = Repo.get_by!(SchedulerApi.Organizations.BusinessMembership, business_id: audit.business_id, user_id: audit.target_user_id)
      grant = Repo.get_by!(SchedulerApi.Organizations.RoleAssignment, membership_id: member.id, role: :business_owner, status: :active)
      unless grant.business_id == shop.business_id and is_nil(grant.shop_id), do: raise("Signup grant scope mismatch")
      proof = Repo.one!(from p in SchedulerApi.Provisioning.Onboarding.Proof, where: p.user_id == ^audit.target_user_id and not is_nil(p.consumed_at))
      unless proof.result["business_id"] == shop.business_id and proof.result["shop_id"] == shop.id, do: raise("Signup receipt mismatch")
    end

    expired_identity = Enum.find(fixture["users"], &(&1["kind"] == "shop_manager"))
    expired_user = Repo.get_by!(User, keycloak_subject: expired_identity["subject"])
    remaining = Repo.all(from s in WebSession, where: is_nil(s.revoked_at))

    unless length(remaining) == 1 and
             Enum.all?(remaining, fn s ->
               s.user_id == expired_user.id and
                 DateTime.compare(s.idle_expires_at, DateTime.utc_now()) != :gt
             end),
           do:
             raise(
               "Expected only the explicitly expired fixture session; all logout sessions must be revoked"
             )

    created =
      Repo.all(
        from e in SchedulerApi.Employment.EmploymentRecord, where: e.first_name == "Created"
      )

    roots = Enum.filter(created, &(&1.id == &1.employee_id))
    current = Enum.filter(created, &(&1.id != &1.employee_id))

    unless length(roots) == 2 and length(current) == 2 and
             Enum.all?(roots, &(is_nil(&1.user_id) and &1.status == :ended)) and
             Enum.all?(
               current,
               &(is_nil(&1.user_id) and &1.status == :active and &1.home_address == nil)
             ),
           do: raise("Termination/rehire browser fixture state invalid")

    current_ids = Enum.map(current, & &1.id)

    unless Repo.aggregate(
             from(a in SchedulerApi.Employment.ShopAssignment,
               where: a.employment_id in ^current_ids
             ),
             :count
           ) == 0,
           do: raise("Rehire restored old shop assignments")

    unless Repo.aggregate(SchedulerApi.Organizations.RoleAssignment, :count) == 10 + length(signup_audits),
      do: raise("Classification edits must not create role grants")

    IO.puts("AUTH_E2E_VERIFIED")

  "prepare_crew" ->
    # Disposable run-owned staff, created only after dashboard-count acceptance.
    business = Repo.get_by!(SchedulerApi.Organizations.Business, slug: fixture["run_id"] <> "-a")

    existing =
      Repo.get_by(SchedulerApi.Employment.EmploymentRecord,
        business_id: business.id,
        first_name: "Crew",
        last_name: "Candidate"
      )

    unless existing do
      shop =
        Repo.get_by!(SchedulerApi.Organizations.Shop, business_id: business.id, slug: "shop-1")

      shift =
        Repo.one!(
          from w in SchedulerApi.Employment.WorkShift,
            where: w.shop_id == ^shop.id and w.status == :active,
            order_by: w.id,
            limit: 1
        )

      {:ok, employee} =
        SchedulerApi.Employment.create_employment(business, %{
          first_name: "Crew",
          last_name: "Candidate",
          classification: :detailer,
          starts_on: ~D[2026-01-01]
        })

      {:ok, assignment} =
        SchedulerApi.Employment.assign_shop(employee, shop, %{starts_on: ~D[2026-01-01]})

      Repo.insert!(%SchedulerApi.Employment.WorkShift{
        employment_id: employee.id,
        assignment_id: assignment.id,
        business_id: business.id,
        shop_id: shop.id,
        timezone: shop.timezone,
        starts_at: shift.starts_at,
        ends_at: shift.ends_at
      })
    end

  "cleanup" ->
    subjects = Enum.map(fixture["users"], & &1["subject"])

    ids =
      Repo.all(
        from u in User,
          where:
            u.keycloak_issuer == ^issuer and
              u.keycloak_subject in ^subjects,
          select: u.id
      )

    businesses =
      Repo.all(
        from b in SchedulerApi.Organizations.Business,
          where: b.slug in ^[fixture["run_id"] <> "-a", fixture["run_id"] <> "-b"],
          select: b.id
      )

    signup_businesses = Repo.all(from i in SchedulerApi.Provisioning.Intent,
      where: i.owner_id in ^ids and i.source == :self_service_signup, select: i.business_id)
    businesses = Enum.uniq(businesses ++ signup_businesses)
    Repo.transaction(fn ->
      draft_ids = Repo.all(from d in SchedulerApi.BusinessOnboarding.Draft,
        where: d.business_id in ^businesses, select: d.id)
      Repo.delete_all(from r in "business_onboarding_receipts", where: r.draft_id in ^draft_ids)
      Repo.delete_all(from e in "business_onboarding_events", where: e.draft_id in ^draft_ids)
      Repo.delete_all(from d in SchedulerApi.BusinessOnboarding.Draft, where: d.id in ^draft_ids)

      Repo.delete_all(from p in SchedulerApi.Provisioning.Onboarding.Proof, where: p.user_id in ^ids)
      Repo.delete_all(from i in SchedulerApi.Provisioning.Intent, where: i.owner_id in ^ids and i.source == :self_service_signup)
      for id <- ids, kind <- ["proof", "creation"] do
        key = :crypto.hash(:sha256, kind <> ":" <> to_string(id))
        Repo.delete_all(from l in "signup_limits", where: l.key == ^key)
      end
      # Exclusive _auth_e2e runner owns these local-proxy attempt buckets.
      for ip <- ["127.0.0.1", "::1"] do
        key = :crypto.hash(:sha256, "ip:" <> ip)
        Repo.delete_all(from l in "signup_limits", where: l.key == ^key)
      end
      Repo.delete_all(
        from h in SchedulerApi.Employment.HrAuditEvent, where: h.business_id in ^businesses
      )

      Repo.delete_all(
        from e in SchedulerApi.Authorization.AuditEvent, where: e.business_id in ^businesses
      )

      Repo.delete_all(
        from event in SchedulerApi.Appointments.JobAssignmentAuditEvent,
          where: event.business_id in ^businesses
      )

      Repo.delete_all(
        from event in SchedulerApi.Employment.WorkShiftAuditEvent,
          where: event.business_id in ^businesses
      )

      Repo.delete_all(
        from j in SchedulerApi.Appointments.JobAssignment, where: j.business_id in ^businesses
      )

      Repo.delete_all(
        from w in SchedulerApi.Employment.WorkShift, where: w.business_id in ^businesses
      )

      Repo.delete_all(
        from sa in SchedulerApi.Employment.ShopAssignment, where: sa.business_id in ^businesses
      )

      Repo.delete_all(
        from ap in SchedulerApi.Appointments.Appointment, where: ap.business_id in ^businesses
      )

      Repo.delete_all(
        from p in SchedulerApi.Catalog.ServicePrice, where: p.business_id in ^businesses
      )

      Repo.delete_all(from s in SchedulerApi.Catalog.Service, where: s.business_id in ^businesses)

      Repo.delete_all(
        from v in SchedulerApi.Catalog.VehicleSize, where: v.business_id in ^businesses
      )

      Repo.delete_all(
        from h in SchedulerApi.Employment.RehireAudit, where: h.business_id in ^businesses
      )

      Repo.delete_all(
        from h in SchedulerApi.Employment.OffboardingAudit, where: h.business_id in ^businesses
      )

      Repo.delete_all(
        from h in SchedulerApi.Employment.ClassificationHistory,
          where: h.business_id in ^businesses
      )

      Repo.delete_all(
        from e in SchedulerApi.Employment.EmploymentRecord, where: e.business_id in ^businesses
      )

      Repo.delete_all(
        from r in SchedulerApi.Organizations.RoleAssignment, where: r.business_id in ^businesses
      )

      Repo.delete_all(
        from m in SchedulerApi.Organizations.BusinessMembership,
          where: m.business_id in ^businesses
      )

      Repo.delete_all(
        from s in SchedulerApi.Organizations.Shop, where: s.business_id in ^businesses
      )

      Repo.delete_all(from b in SchedulerApi.Organizations.Business, where: b.id in ^businesses)
      Repo.delete_all(from s in WebSession, where: s.user_id in ^ids)
      Repo.delete_all(from u in User, where: u.id in ^ids)
      # This dedicated database was verified empty before this exclusive run.
      Repo.delete_all(LoginTransaction)
    end)

    IO.puts("AUTH_E2E_CLEANED")

  action when action in ["revoke_mixed", "expire_shop_manager", "check_seed"] ->
    if action == "check_seed" do
      unless Repo.aggregate(User, :count) == 7, do: raise("Fixture users missing")

      for identity <- fixture["users"], identity["kind"] not in ["pending", "registration"] do
        user = Repo.get_by!(User, keycloak_subject: identity["subject"])

        expected =
          case identity["kind"] do
            k when k in ["active", "employee"] -> 0
            k when k in ["mixed", "multi_owner"] -> 2
            _ -> 1
          end

        unless length(SchedulerApi.Authorization.admin_contexts(user)) == expected,
          do: raise("Fixture context mismatch")
      end

      IO.puts("AUTH_E2E_FIXTURES_READY")
    else
      kind = if action == "revoke_mixed", do: "mixed", else: "shop_manager"
      identity = Enum.find(fixture["users"], &(&1["kind"] == kind))

      user =
        Repo.get_by!(User,
          keycloak_issuer: issuer,
          keycloak_subject: identity["subject"]
        )

      if action == "revoke_mixed" do
        business =
          Repo.get_by!(SchedulerApi.Organizations.Business, slug: fixture["run_id"] <> "-a")

        membership =
          Repo.get_by!(SchedulerApi.Organizations.BusinessMembership,
            business_id: business.id,
            user_id: user.id
          )

        actor_identity = Enum.find(fixture["users"], &(&1["kind"] == "owner"))

        actor =
          Repo.get_by!(User,
            keycloak_issuer: issuer,
            keycloak_subject: actor_identity["subject"]
          )

        {:ok, session, credential} = Accounts.create_session(actor)

        try do
          {:ok, _} =
            SchedulerApi.Authorization.RoleManagement.revoke_membership(
              credential,
              business,
              membership
            )
        after
          {:ok, _} = Accounts.revoke_session(session, :logout)
        end
      else
        # Advance only owned test-session timestamps, without sleeps or browser-token access.
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.update_all(
          from(s in WebSession, where: s.user_id == ^user.id and is_nil(s.revoked_at)),
          set: [
            inserted_at: DateTime.add(now, -7200),
            last_seen_at: DateTime.add(now, -3600),
            idle_expires_at: DateTime.add(now, -1800)
          ]
        )
      end
    end

  "server" ->
    deadline = System.monotonic_time(:millisecond) + 30_000

    wait = fn wait ->
      case SchedulerApi.Authentication.Provider.context() do
        {:ok, _, _} ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) >= deadline,
            do: raise("OIDC discovery unavailable")

          receive do
          after
            100 -> wait.(wait)
          end
      end
    end

    wait.(wait)
    IO.puts("AUTH_E2E_READY")

    receive do
      :stop -> :ok
    end
end
