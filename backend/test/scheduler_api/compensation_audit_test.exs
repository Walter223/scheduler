defmodule SchedulerApi.CompensationAuditTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.CompensationFixtures
  alias SchedulerApi.Employment.{Compensation, CompensationRate, CompensationAuditEvent}

  @now ~U[2026-10-29 18:00:00Z]
  setup do: compensation_fixture()

  test "audit failure rolls back both the previous period closure and the new rate", c do
    attrs = %{amount: "25.00", pay_basis: :hourly, effective_from: ~D[2026-10-29]}
    assert {:ok, first} = Compensation.set_rate(c.credential, c.employment, attrs, now: @now)
    before = Repo.aggregate(CompensationAuditEvent, :count)
    # Transaction-local database fault, never an application bypass or test flag.
    Repo.query!(
      "ALTER TABLE compensation_audit_events ADD CONSTRAINT compensation_test_audit_failure CHECK (business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             Compensation.set_rate(
               c.credential,
               c.employment,
               %{attrs | amount: "30.00", effective_from: ~D[2026-11-01]},
               now: @now
             )

    assert Repo.aggregate(CompensationRate, :count) == 1
    assert Repo.get!(CompensationRate, first.id).effective_until == nil
    assert Repo.aggregate(CompensationAuditEvent, :count) == before
    assert {:ok, current} = Compensation.get_current_rate(c.owner, c.employment, now: @now)
    assert current.amount == "25.00"
  end

  test "database insertion failure also rolls back the old period closure without a false audit",
       c do
    attrs = %{amount: "25.00", pay_basis: :hourly, effective_from: ~D[2026-10-29]}
    assert {:ok, first} = Compensation.set_rate(c.credential, c.employment, attrs, now: @now)
    before = Repo.aggregate(CompensationAuditEvent, :count)

    Repo.query!(
      "ALTER TABLE compensation_rates ADD CONSTRAINT compensation_test_rate_failure CHECK (amount <> 30) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             Compensation.set_rate(
               c.credential,
               c.employment,
               %{attrs | amount: "30.00", effective_from: ~D[2026-11-01]},
               now: @now
             )

    assert Repo.aggregate(CompensationRate, :count) == 1
    assert Repo.get!(CompensationRate, first.id).effective_until == nil
    assert Repo.aggregate(CompensationAuditEvent, :count) == before
  end

  test "rejected attempts fail closed too if their denial audit cannot be stored", c do
    Repo.query!(
      "ALTER TABLE compensation_audit_events ADD CONSTRAINT compensation_test_denial_audit_failure CHECK (business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             Compensation.set_rate(nil, c.employment, %{}, now: @now)

    assert Repo.aggregate(CompensationRate, :count) == 0
    assert Repo.aggregate(CompensationAuditEvent, :count) == 0
  end
end
