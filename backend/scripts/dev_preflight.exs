# Local development connection verification only; never boots Magnum or migrates.
try do
  opts = Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)

  unless Mix.env() == :dev and opts[:database] == "scheduler_api_dev" and
           opts[:hostname] in ["localhost", "127.0.0.1"] and
           Keyword.get(opts, :port, 5432) == 5432 and opts[:username] == "postgres" and
           is_nil(opts[:url]) and is_nil(opts[:socket_dir]) do
    raise "Unexpected development target"
  end

  {:ok, _} = Application.ensure_all_started(:postgrex)

  {:ok, connection} =
    Postgrex.start_link(Keyword.take(opts, [:hostname, :port, :username, :password, :database]))

  Postgrex.query!(connection, "SET default_transaction_read_only = on", [])

  %{rows: [[database, address, port]]} =
    Postgrex.query!(
      connection,
      "SELECT current_database(), host(inet_server_addr()), inet_server_port()",
      []
    )

  unless database == "scheduler_api_dev" and address in ["127.0.0.1", "::1"] and port == 5432,
    do: raise("Unexpected server target")

  %{rows: versions} =
    Postgrex.query!(connection, "SELECT version FROM schema_migrations ORDER BY version", [])

  %{rows: tables} =
    Postgrex.query!(
      connection,
      "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' AND table_name <> 'schema_migrations' ORDER BY table_name",
      []
    )

  snapshot =
    if System.get_env("MAGNUM_DEV_BACKUP") || System.get_env("MAGNUM_DEV_BASELINE"),
      do:
        Map.new(tables, fn [table] ->
          %{rows: columns} =
            Postgrex.query!(
              connection,
              "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 ORDER BY ordinal_position",
              [table]
            )

          quote_id = fn value -> "\"" <> String.replace(value, "\"", "\"\"") <> "\"" end
          # Compare original columns after additive migrations, not newly added defaults.
          selection = Enum.map_join(columns, ",", fn [column] -> quote_id.(column) end)
          path = System.get_env("MAGNUM_DEV_BASELINE")
          original = if path && File.exists?(path), do: Jason.decode!(File.read!(path)), else: %{}
          names = get_in(original, [table, "columns"]) || Enum.map(columns, &hd/1)

          selection =
            if names == Enum.map(columns, &hd/1),
              do: selection,
              else: Enum.map_join(names, ",", quote_id)

          sql =
            "SELECT count(*), md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text, '[]')) FROM (SELECT " <>
              selection <> " FROM " <> quote_id.(table) <> ") t"

          %{rows: [[count, digest]]} = Postgrex.query!(connection, sql, [])
          {table, %{columns: names, count: count, digest: digest}}
        end),
      else: %{}

  backup = System.get_env("MAGNUM_DEV_BACKUP")

  if backup do
    env = [{"PGPASSWORD", opts[:password] || ""}]

    args = [
      "--host=127.0.0.1",
      "--port=5432",
      "--username=postgres",
      "--dbname=scheduler_api_dev",
      "--no-password",
      "--format=custom",
      "--file=" <> backup
    ]

    {_, 0} = System.cmd("pg_dump", args, env: env, stderr_to_stdout: true)
    File.chmod!(backup, 0o600)
    {_, 0} = System.cmd("pg_restore", ["--file=/dev/null", backup], stderr_to_stdout: true)
  end

  IO.puts(
    "MAGNUM_DEV_PREFLIGHT " <>
      Jason.encode!(%{
        database: database,
        host: address,
        port: port,
        versions: List.flatten(versions),
        snapshot: snapshot
      })
  )
rescue
  error ->
    IO.puts(
      :stderr,
      "Development database verification/backup failed (" <>
        inspect(error.__struct__) <> "); no migration performed"
    )

    System.halt(1)
end
