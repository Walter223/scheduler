defmodule SchedulerApi.Repo do
  use Ecto.Repo,
    otp_app: :scheduler_api,
    adapter: Ecto.Adapters.Postgres
end
