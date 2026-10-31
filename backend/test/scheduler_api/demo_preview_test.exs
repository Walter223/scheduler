defmodule SchedulerApi.Development.DemoPreviewTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.JobAssignmentFixtures
  alias SchedulerApi.{Repo, Accounts}
  alias SchedulerApi.Development.DemoPreview
  alias SchedulerApi.Appointments.Appointment
  alias SchedulerApi.Organizations.Shop

  test "dry-run is read-only; apply is atomic, scoped, authorized and idempotent" do
    c = job_fixture()
    before = Repo.get!(Appointment, c.booking.id)
    shop = Repo.get!(Shop, c.shop.id)
    counts = {Repo.aggregate(Shop, :count), Repo.aggregate(Appointment, :count)}
    assert DemoPreview.plan(c.owner.id, c.business.id).mode == :create
    assert counts == {Repo.aggregate(Shop, :count), Repo.aggregate(Appointment, :count)}
    assert_raise MatchError, fn -> DemoPreview.plan(c.detailer.id, c.business.id) end
    result = DemoPreview.apply(c.owner.id, c.business.id)
    assert result.mode == :created
    assert result.appointments == 6
    assert DemoPreview.apply(c.owner.id, c.business.id).mode == :existing

    assert DemoPreview.verify(c.owner.id, c.business.id) == %{
             shops: 2,
             employment_records: 5,
             authorized_reads: :passed
           }

    assert Repo.get!(Appointment, c.booking.id) == before
    assert Repo.get!(Shop, c.shop.id) == shop
    assert Repo.aggregate(Shop, :count) == elem(counts, 0) + 2
    assert Repo.aggregate(Appointment, :count) == elem(counts, 1) + 6
    # Current eligibility is checked again, even for an already-present fixture.
    {:ok, _} = Accounts.set_user_status(c.owner, :suspended)
    assert_raise MatchError, fn -> DemoPreview.apply(c.owner.id, c.business.id) end
  end

  test "audit failure rolls back every demo row and temporary operator session" do
    c = job_fixture()

    counts =
      for schema <- [
            Shop,
            Appointment,
            SchedulerApi.Employment.EmploymentRecord,
            SchedulerApi.Accounts.WebSession
          ],
          do: Repo.aggregate(schema, :count)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_demo_hr() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'isolated test audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_demo_hr BEFORE INSERT ON employment_hr_audit_events FOR EACH ROW WHEN (NEW.business_id = #{c.business.id}) EXECUTE FUNCTION pg_temp.reject_demo_hr()"
    )

    try do
      assert_raise MatchError, fn -> DemoPreview.apply(c.owner.id, c.business.id) end
    after
      Repo.query!("DROP TRIGGER reject_demo_hr ON employment_hr_audit_events")
    end

    assert counts ==
             for(
               schema <- [
                 Shop,
                 Appointment,
                 SchedulerApi.Employment.EmploymentRecord,
                 SchedulerApi.Accounts.WebSession
               ],
               do: Repo.aggregate(schema, :count)
             )
  end
end
