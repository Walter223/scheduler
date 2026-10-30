defmodule SchedulerApi.EmploymentHRAuditTest do
  use SchedulerApi.DataCase, async: false
  import SchedulerApi.CompensationFixtures

  alias SchedulerApi.Employment.{
    HR,
    EmploymentRecord,
    ShopAssignment,
    ClassificationHistory,
    HrAuditEvent
  }

  setup do: compensation_fixture()

  test "audit failure rolls back creation, contact, classification/history and shop creation, including denials",
       c do
    before = Repo.all(ClassificationHistory)

    Repo.query!(
      "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT test_hr_audit_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             HR.create_employment(c.credential, c.business, %{
               first_name: "A",
               last_name: "B",
               classification: :detailer,
               starts_on: ~D[2026-01-01]
             })

    assert {:error, :persistence_failed} =
             HR.update_contact(c.credential, c.employment, %{phone: "private"})

    assert {:error, :persistence_failed} =
             HR.change_classification(c.credential, c.employment, :shop_manager)

    assert {:error, :persistence_failed} =
             HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

    assert {:error, :persistence_failed} = HR.update_contact(nil, c.employment, %{phone: "x"})
    assert Repo.all(ClassificationHistory) == before
    assert Repo.aggregate(EmploymentRecord, :count) == 1
    assert Repo.aggregate(ShopAssignment, :count) == 0
    assert Repo.aggregate(HrAuditEvent, :count) == 0
    assert Repo.reload!(c.employment) == c.employment
  end

  test "assignment ending is also rolled back if its audit fails", c do
    {:ok, a} = HR.assign_shop(c.credential, c.employment, c.shop, %{starts_on: ~D[2026-01-01]})

    Repo.query!(
      "ALTER TABLE employment_hr_audit_events ADD CONSTRAINT test_hr_audit_failure CHECK(business_id <> #{c.business.id}) NOT VALID"
    )

    assert {:error, :persistence_failed} =
             HR.end_shop_assignment(c.credential, %ShopAssignment{id: a.id}, ~D[2026-10-30])

    assert Repo.get!(ShopAssignment, a.id).status == :active
    assert Repo.aggregate(HrAuditEvent, :count) == 1
  end

  test "history and audit are immutable, scoped and restrict employment deletion", c do
    {:ok, _} = HR.change_classification(c.credential, c.employment, :shop_manager)
    h = Repo.one!(from h in ClassificationHistory, where: h.source == :changed)
    event = Repo.one!(HrAuditEvent)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE employment_classification_history SET classification='detailer' WHERE id=$1",
               [h.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE employment_hr_audit_events SET actor_user_id=NULL WHERE id=$1",
               [event.id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Repo.query("DELETE FROM employments WHERE id=$1", [c.employment.id],
               mode: :savepoint
             )

    foreign = compensation_fixture()

    unreferenced =
      Repo.one!(
        from history in ClassificationHistory,
          where: history.employment_id == ^c.employment.id and history.source == :created
      )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "INSERT INTO employment_hr_audit_events(actor_user_id,business_id,employment_id,classification_history_id,action,outcome,reason,occurred_at) VALUES($1,$2,$3,$4,'change_classification','applied','reclassified',$5)",
               [
                 c.owner.id,
                 foreign.business.id,
                 foreign.employment.id,
                 unreferenced.id,
                 DateTime.to_naive(event.occurred_at)
               ],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "INSERT INTO employment_hr_audit_events(actor_user_id,business_id,employment_id,changed_fields,action,outcome,reason,occurred_at) VALUES($1,$2,$3,ARRAY['ssn'],'edit_contact','applied','updated',$4)",
               [c.owner.id, c.business.id, c.employment.id, DateTime.to_naive(event.occurred_at)],
               mode: :savepoint
             )
  end
end
