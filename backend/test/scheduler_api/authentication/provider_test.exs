defmodule SchedulerApi.Authentication.ProviderTest do
  use ExUnit.Case, async: false
  import SchedulerApi.OidcFixtures
  alias SchedulerApi.Authentication.{Config, Provider}

  test "authentication is disabled by default and no provider worker starts" do
    assert {:error, :auth_disabled} = Config.current()
    assert Provider.children() == []
    refute Process.whereis(SchedulerApi.Authentication.ProviderWorker)
    assert {:error, :auth_disabled} = Provider.context()
    assert Process.whereis(SchedulerApi.Supervisor)
  end

  test "HTTP is allowed only for the exact local development issuer and callback" do
    options = [
      issuer: "http://auth.magnum.test:8080/realms/magnum",
      callback_url: "http://localhost:4000/auth/callback",
      client_secret: "test-only"
    ]

    assert {:ok, config} = Config.new(options, :dev)
    assert config.local_http
    assert {:error, :invalid_provider_config} = Config.new(options, :prod)

    assert {:error, :invalid_provider_config} =
             Config.new(Keyword.put(options, :issuer, "http://evil.invalid"), :dev)

    assert {:error, :invalid_provider_config} =
             Config.new(
               Keyword.put(options, :issuer, "http://auth.magnum.test:8080/realms/magnum/"),
               :dev
             )

    assert {:error, :invalid_provider_config} =
             Config.new(Keyword.put(options, :client_id, "other"), :dev)

    assert {:ok, _} =
             Config.new(
               Map.from_struct(config())
               |> Map.take([:issuer, :client_secret, :callback_url])
               |> Map.to_list(),
               :prod
             )

    refute inspect(config) =~ "test-only"
  end

  @tag capture_log: true
  test "worker has bounded retry configuration and actual provider outage does not stop application" do
    config = config()
    options = Config.worker_options(config)
    assert options.backoff_type == :random_exponential
    assert options.backoff_min == 1_000
    assert options.backoff_max == 30_000
    assert options.provider_configuration_opts.request_opts.timeout == 5_000

    # Reserve a local port without listening: deterministic connection refusal.
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    options = %{options | issuer: "https://127.0.0.1:#{port}", name: __MODULE__.Unavailable}
    parent = self()
    handler = "oidc-outage-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:oidcc, :load_configuration, :stop],
        fn _, _, metadata, _ ->
          if Map.has_key?(metadata, :error), do: send(parent, :discovery_failed)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    pid = start_supervised!({Oidcc.ProviderConfiguration.Worker, options})
    ref = Process.monitor(pid)
    assert_receive :discovery_failed, 6_000
    # The failed continue has completed; worker is waiting for bounded retry.
    state = :sys.get_state(pid)
    assert is_tuple(state)
    refute_received {:DOWN, ^ref, :process, ^pid, _}
    assert Process.whereis(SchedulerApi.Supervisor)

    assert {:error, :provider_not_ready} =
             Oidcc.ClientContext.from_configuration_worker(pid, "magnum-web", "test-only")
  end
end
