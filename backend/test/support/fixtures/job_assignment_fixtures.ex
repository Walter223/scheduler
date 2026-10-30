defmodule SchedulerApi.JobAssignmentFixtures do
  import SchedulerApi.ShopsFixtures
  import SchedulerApi.AccountsFixtures
  import SchedulerApi.AdminAccessFixtures
  import SchedulerApi.EmploymentFixtures
  import SchedulerApi.AppointmentsFixtures
  alias SchedulerApi.{Accounts, Appointments, Employment, Repo}
  alias SchedulerApi.Organizations.Business
  alias SchedulerApi.Employment.WorkSchedules

  def job_fixture do
    %{shop: shop, price: price} = other_business_price_fixture()
    business = Repo.get!(Business, shop.business_id)
    owner = active_user_fixture()
    {membership, grant} = grant_fixture(owner, shop, :business_owner)
    {:ok, session, credential} = Accounts.create_session(owner)
    detailer = active_user_fixture()
    {employee_membership, employee_grant} = grant_fixture(detailer, shop, :employee)
    employment = employment_fixture(%{}, business: business, user: detailer)
    {:ok, assignment} = Employment.assign_shop(employment, shop, %{starts_on: ~D[2026-01-01]})
    {:ok, booking} = Appointments.create_appointment(shop, booking_attrs(price))

    c = %{
      shop: shop,
      price: price,
      business: business,
      owner: owner,
      membership: membership,
      grant: grant,
      session: session,
      credential: credential,
      detailer: detailer,
      employee_membership: employee_membership,
      employee_grant: employee_grant,
      employment: employment,
      assignment: assignment,
      booking: booking
    }

    {:ok, shift} =
      WorkSchedules.create_shift(credential, assignment, %{
        starts_at: booking.starts_at,
        ends_at: DateTime.add(booking.starts_at, 8 * 3600)
      })

    Map.put(c, :shift, shift)
  end

  def second_detailer(c, attrs \\ %{}) do
    e = employment_fixture(attrs, business: c.business)
    {:ok, a} = Employment.assign_shop(e, c.shop, %{starts_on: ~D[2026-01-01]})

    {:ok, s} =
      WorkSchedules.create_shift(c.credential, a, %{
        starts_at: c.shift.starts_at,
        ends_at: c.shift.ends_at
      })

    %{employment: e, assignment: a, shift: s}
  end
end
