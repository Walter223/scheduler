defmodule Mix.Tasks.Magnum.DemoPreview do
  use Mix.Task
  @shortdoc "Explicit local demo fixture; default dry-run, --apply required"
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [owner_user_id: :integer, apply: :boolean, dry_run: :boolean, verify: :boolean]
      )

    unless Mix.env() == :dev and rest == [] and invalid == [] and is_integer(opts[:owner_user_id]) and
             not (opts[:apply] == true and opts[:dry_run] == true),
           do:
             Mix.raise(
               "Development only: mix magnum.demo_preview --owner-user-id ID [--dry-run|--apply|--verify]"
             )

    unless Application.fetch_env!(:scheduler_api, SchedulerApi.Repo)[:database] ==
             "scheduler_api_dev",
           do: Mix.raise("Expected local development database")

    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    operation =
      cond do
        opts[:verify] -> :verify
        opts[:apply] -> :apply
        true -> :plan
      end

    result = apply(SchedulerApi.Development.DemoPreview, operation, [opts[:owner_user_id], 1])
    Mix.shell().info(inspect(result, pretty: true))
  end
end
