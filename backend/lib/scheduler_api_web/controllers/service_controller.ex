defmodule SchedulerApiWeb.ServiceController do
  use SchedulerApiWeb, :controller

  def index(conn, _params) do
    services = [
      %{
        id: 1,
        name: "Basic Detail",
        description:
          "A simple wash, dry, and basic spray detail of the outside - no interior detail"
      },
      %{
        id: 2,
        name: "Mid Detail",
        description:
          "Wash, clay bar, and spray detail the outside - interior detail with surface cleaning"
      },
      %{
        id: 3,
        name: "Supreme Detail",
        description:
          "Wash, clay bar, tire shine, and wax the outside - interior detail with surface cleaning, shampooing, and choice of spray smell"
      }
    ]

    json(conn, services)
  end
end
