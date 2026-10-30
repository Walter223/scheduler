defmodule SchedulerApi.WorkShiftAuditTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.WorkShiftFixtures
  alias SchedulerApi.Employment.{WorkSchedules, WorkShift, WorkShiftAuditEvent}
  @now ~U[2026-10-30 12:00:00Z]
  @attrs %{starts_at: ~U[2026-11-02 16:00:00Z], ends_at: ~U[2026-11-02 19:00:00Z]}
  setup do: work_shift_fixture()

  test "failed audit rolls back creation, cancellation and replacement as a whole", c do
    {:ok, original} = WorkSchedules.create_shift(c.credential, c.assignment, @attrs, now: @now)

    Repo.query!(
      "ALTER TABLE work_shift_audit_events ADD CONSTRAINT test_shift_audit_failure CHECK (business_id <> #{c.business.id}) NOT VALID"
    )

    ref = %WorkShift{id: original.id}
    later = %{starts_at: ~U[2026-11-03 16:00:00Z], ends_at: ~U[2026-11-03 19:00:00Z]}

    assert {:error, :persistence_failed} =
             WorkSchedules.create_shift(c.credential, c.assignment, later, now: @now)

    assert {:error, :persistence_failed} =
             WorkSchedules.cancel_shift(c.credential, ref, now: @now)

    assert {:error, :persistence_failed} =
             WorkSchedules.reschedule_shift(c.credential, ref, later, now: @now)

    assert Repo.aggregate(WorkShift, :count) == 1
    assert Repo.get!(WorkShift, original.id).status == :active
    assert Repo.aggregate(WorkShiftAuditEvent, :count) == 1
    # A denial must also fail closed when its audit is unavailable.
    assert {:error, :persistence_failed} = WorkSchedules.cancel_shift(nil, ref, now: @now)
  end

  test "replacement insertion failure restores the old active row and leaves no successful audit",
       c do
    {:ok, original} = WorkSchedules.create_shift(c.credential, c.assignment, @attrs, now: @now)

    Repo.query!(
      "ALTER TABLE work_shifts ADD CONSTRAINT test_shift_insert_failure CHECK (starts_at <> timestamp '2026-11-03 16:00:00') NOT VALID"
    )

    assert {:error, :persistence_failed} =
             WorkSchedules.reschedule_shift(
               c.credential,
               %WorkShift{id: original.id},
               %{starts_at: ~U[2026-11-03 16:00:00Z], ends_at: ~U[2026-11-03 19:00:00Z]},
               now: @now
             )

    assert Repo.get!(WorkShift, original.id).status == :active
    assert Repo.aggregate(WorkShift, :count) == 1
    assert Repo.aggregate(WorkShiftAuditEvent, :count) == 1
  end

  test "audit snapshots cannot be forged across assignments or rewritten", c do
    {:ok, shift} = WorkSchedules.create_shift(c.credential, c.assignment, @attrs, now: @now)
    foreign = work_shift_fixture()

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "INSERT INTO work_shift_audit_events(actor_user_id,assignment_id,employment_id,business_id,shop_id,shift_id,action,outcome,reason,occurred_at) VALUES($1,$2,$3,$4,$5,$6,'cancel','denied','forbidden',$7)",
               [
                 c.owner.id,
                 foreign.assignment.id,
                 foreign.employment.id,
                 foreign.business.id,
                 foreign.shop.id,
                 shift.id,
                 DateTime.to_naive(@now)
               ],
               mode: :savepoint
             )

    audit = Repo.one!(WorkShiftAuditEvent)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE work_shift_audit_events SET outcome='denied' WHERE id=$1",
               [audit.id],
               mode: :savepoint
             )

    for field <- [:amount, :email, :home_address, :token, :ssn, :bank_account] do
      refute field in WorkShiftAuditEvent.__schema__(:fields)
    end
  end
end
