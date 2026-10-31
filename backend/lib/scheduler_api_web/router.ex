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

    get "/context", AdminContextController, :index, log: false
    get "/appointments", AppointmentController, :index, log: false
    get "/businesses/:business_id/employees", EmployeeController, :index, log: false
    get "/businesses/:business_id/shops/:shop_id/employees", EmployeeController, :shop, log: false
    get "/businesses/:business_id/employees/:employee_id", EmployeeController, :show, log: false

    get "/businesses/:business_id/employees/:employee_id/periods", EmployeeController, :history,
      log: false

    get "/businesses/:business_id/employees/:employee_id/periods/:period_id",
        EmployeeController,
        :period, log: false
  end

  pipeline :admin_write do
    plug SchedulerApiWeb.RequireBrowserSession
    plug :accepts, ["json"]
    plug SchedulerApiWeb.SessionCSRF
    plug SchedulerApiWeb.AdminJSONBody
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_write
    post "/employees", EmployeeWriteController, :create, log: false

    patch "/employees/:employee_id/periods/:period_id/contact", EmployeeWriteController, :contact,
      log: false

    patch "/employees/:employee_id/periods/:period_id/classification",
          EmployeeWriteController,
          :classification, log: false

    post "/employees/:employee_id/periods/:period_id/shop-assignments",
         EmployeeWriteController,
         :assign_shop, log: false

    post "/employees/:employee_id/periods/:period_id/shop-assignments/:assignment_id/end",
         EmployeeWriteController,
         :end_shop, log: false

    post "/employees/:employee_id/periods/:period_id/terminate",
         EmployeeWriteController,
         :terminate, log: false

    post "/employees/:employee_id/periods/:period_id/rehire", EmployeeWriteController, :rehire,
      log: false
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_api
    get "/shops/:shop_id/appointments", SchedulingController, :appointments, log: false

    get "/shops/:shop_id/appointments/:appointment_id/team", SchedulingController, :team,
      log: false

    get "/shops/:shop_id/shifts", SchedulingController, :shifts, log: false

    get "/shops/:shop_id/employees/:employee_id/periods/:period_id/shifts",
        SchedulingController,
        :employee_shifts, log: false

    get "/me/shifts", SchedulingController, :own_shifts, log: false
    get "/me/work", SchedulingController, :own_jobs, log: false
  end

  scope "/api/admin/businesses/:business_id/shops/:shop_id", SchedulerApiWeb do
    pipe_through :admin_write
    post "/shifts", SchedulingController, :create_shift, log: false
    post "/shifts/:shift_id/cancel", SchedulingController, :cancel_shift, log: false
    post "/shifts/:shift_id/reschedule", SchedulingController, :reschedule_shift, log: false
    post "/appointments/:appointment_id/team", SchedulingController, :add, log: false

    post "/appointments/:appointment_id/team/:job_id/remove", SchedulingController, :remove,
      log: false

    post "/appointments/:appointment_id/team/:job_id/lead", SchedulingController, :lead,
      log: false

    post "/appointments/:appointment_id/team/clear-lead", SchedulingController, :clear_lead,
      log: false
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_api

    get "/employees/:employee_id/periods/:period_id/compensation/current",
        CompensationController,
        :current, log: false

    get "/employees/:employee_id/periods/:period_id/compensation/history",
        CompensationController,
        :history, log: false

    get "/me/compensation/current", CompensationController, :own, log: false
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_write

    post "/employees/:employee_id/periods/:period_id/compensation/rates",
         CompensationController,
         :create, log: false
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_api
    get "/memberships", AccessController, :memberships, log: false
    get "/role-grants", AccessController, :role_grants, log: false
  end

  scope "/api/admin/businesses/:business_id", SchedulerApiWeb do
    pipe_through :admin_write
    post "/role-grants", AccessController, :grant, log: false
    post "/role-grants/:grant_id/revoke", AccessController, :revoke, log: false
    post "/memberships/:membership_id/revoke", AccessController, :revoke_membership, log: false

    post "/memberships/:membership_id/reactivate", AccessController, :reactivate_membership,
      log: false
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
