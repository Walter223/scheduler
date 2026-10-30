defmodule Mix.Tasks.Magnum.BootstrapOwner do
  use Mix.Task
  @shortdoc "Dry-run first business Owner provisioning (explicit --apply to write)"
  @moduledoc """
  Deployment operators only. Requires existing active verified identity; no activation.

      mix magnum.bootstrap_owner --business-id 42 --issuer URL --subject SUBJECT [--apply]

  Exact issuer/subject, never email. Default dry-run writes no audit or grants.
  Production: set MIX_ENV=prod and supply normal deployment configuration securely.
  No operator-name argument: the command does not verify human operator identity.
  """
  def run(args) do
    case parse(args) do
      {:ok, id, issuer, subject, apply?} ->
        Mix.Task.run("app.start")

        case SchedulerApi.Authorization.OwnerBootstrap.run(id, issuer, subject, apply: apply?) do
          {:ok, result} ->
            label = if apply?, do: "APPLIED", else: "DRY RUN (no writes; not a reservation)"

            Mix.shell().info(
              "#{label}: business=#{result.business_id} user=#{result.user_id} role=business_owner"
            )

          {:error, reason} ->
            Mix.raise("Owner bootstrap rejected: #{reason}")
        end

      :error ->
        Mix.raise(
          "Usage: mix magnum.bootstrap_owner --business-id ID --issuer URL --subject SUBJECT [--apply]"
        )
    end
  end

  @doc false
  def parse(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [business_id: :integer, issuer: :string, subject: :string, apply: :boolean]
      )

    id = opts[:business_id]
    issuer = opts[:issuer]
    subject = opts[:subject]

    if rest == [] and invalid == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         is_integer(id) and id > 0 and is_binary(issuer) and byte_size(issuer) in 1..1024 and
         is_binary(subject) and byte_size(subject) in 1..1024 do
      {:ok, id, issuer, subject, Keyword.get(opts, :apply, false)}
    else
      :error
    end
  end
end
