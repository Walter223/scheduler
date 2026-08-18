defmodule SchedulerApiWeb.ServiceController do
  use SchedulerApiWeb, :controller

  alias SchedulerApi.Catalog

  def index(conn, _params) do
    services = Catalog.list_services_with_prices()

    render(conn, :index, services: services)
  end
end
