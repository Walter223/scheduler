# Explicit, isolated real-provider fixture runner. Never loaded by the application.
unless Mix.env() == :test and
         Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)[:database] ==
           "scheduler_api_test_auth_e2e" do
  raise "Auth E2E requires MIX_ENV=test and MIX_TEST_PARTITION=_auth_e2e"
end

[command] = System.argv()
fixture = System.fetch_env!("BFF_E2E_FIXTURE") |> File.read!() |> Jason.decode!()
unless Enum.all?(fixture["users"], &String.starts_with?(&1["username"], fixture["run_id"])),
  do: raise("Invalid owned auth fixture")

if command == "server" do
  {:ok, provider} = SchedulerApi.Authentication.Config.new([
    issuer: "http://auth.magnum.test:8080/realms/magnum",
    callback_url: "http://localhost:5173/auth/callback",
    client_secret: System.fetch_env!("MAGNUM_WEB_CLIENT_SECRET")
  ], :dev)
  Application.put_env(:scheduler_api, :oidc, provider)
  {:ok, browser} = SchedulerApi.Authentication.BrowserConfig.new("http://localhost:5173", :dev)
  Application.put_env(:scheduler_api, :browser_auth, browser)
end

endpoint = SchedulerApiWeb.Endpoint
config = Application.fetch_env!(:scheduler_api, endpoint)
Application.put_env(:scheduler_api, endpoint,
  Keyword.merge(config, server: command == "server", http: [ip: {127, 0, 0, 1}, port: 4000]))
{:ok, _} = Application.ensure_all_started(:scheduler_api)
Ecto.Adapters.SQL.Sandbox.mode(SchedulerApi.Repo, :auto)

import Ecto.Query
alias SchedulerApi.{Accounts, Repo}
alias SchedulerApi.Accounts.{User, VerifiedIdentity, WebSession}
alias SchedulerApi.Authentication.LoginTransaction

case command do
  "seed" ->
    # Never overwrite a database containing other identities or login attempts.
    unless Enum.all?([User, WebSession, LoginTransaction], &(Repo.aggregate(&1, :count) == 0)),
      do: raise("Auth E2E database has existing account data; refusing fixture setup")
    active = Enum.find(fixture["users"], &(&1["kind"] == "active"))
    {:ok, user} = Accounts.sync_verified_identity(%VerifiedIdentity{
      issuer: "http://auth.magnum.test:8080/realms/magnum", subject: active["subject"],
      email: active["email"], email_verified: true, first_name: "E2E", last_name: "Active"})
    {:ok, _} = Accounts.set_user_status(user, :active)
    IO.puts("AUTH_E2E_SEEDED")

  "verify" ->
    subjects = Enum.map(fixture["users"], & &1["subject"])
    users = Repo.all(from u in User, where: u.keycloak_subject in ^subjects)
    unless Enum.sort(Enum.map(users, & &1.status)) == [:active, :pending],
      do: raise("Expected active and denied pending identities")
    unless Repo.aggregate(from(s in WebSession, where: is_nil(s.revoked_at)), :count) == 0,
      do: raise("Logout did not durably revoke all issued test sessions")
    IO.puts("AUTH_E2E_VERIFIED")

  "cleanup" ->
    subjects = Enum.map(fixture["users"], & &1["subject"])
    ids = Repo.all(from u in User, where: u.keycloak_issuer == "http://auth.magnum.test:8080/realms/magnum"
      and u.keycloak_subject in ^subjects, select: u.id)
    Repo.transaction(fn ->
      Repo.delete_all(from s in WebSession, where: s.user_id in ^ids)
      Repo.delete_all(from u in User, where: u.id in ^ids)
      # This dedicated database was verified empty before this exclusive run.
      Repo.delete_all(LoginTransaction)
    end)
    IO.puts("AUTH_E2E_CLEANED")

  "server" ->
    deadline = System.monotonic_time(:millisecond) + 30_000
    wait = fn wait ->
      case SchedulerApi.Authentication.Provider.context() do
        {:ok, _, _} -> :ok
        _ ->
          if System.monotonic_time(:millisecond) >= deadline, do: raise("OIDC discovery unavailable")
          receive do after 100 -> wait.(wait) end
      end
    end
    wait.(wait)
    IO.puts("AUTH_E2E_READY")
    receive do :stop -> :ok end
end
