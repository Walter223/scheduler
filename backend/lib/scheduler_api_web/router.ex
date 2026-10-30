defmodule SchedulerApiWeb.Router do
  use SchedulerApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/auth", SchedulerApiWeb do
    get "/login", AuthController, :login, log: false
    get "/callback", AuthController, :callback, log: false
    post "/logout", AuthController, :logout, log: false
  end

  scope "/api", SchedulerApiWeb do
    pipe_through :api

    get "/me", AuthController, :me, log: false

    get "/services", ServiceController, :index
    get "/availability", AvailabilityController, :index
    post "/appointments", AppointmentController, :create
  end

  pipeline :admin_api do
    plug SchedulerApiWeb.RequireBrowserSession
    plug :accepts, ["json"]
  end

  scope "/api/admin", SchedulerApiWeb do
    pipe_through :admin_api

    get "/appointments", AppointmentController, :index, log: false
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:scheduler_api, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: SchedulerApiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
