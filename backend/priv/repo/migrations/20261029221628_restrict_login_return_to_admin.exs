defmodule SchedulerApi.Repo.Migrations.RestrictLoginReturnToAdmin do
  use Ecto.Migration

  def up do
    drop constraint(:login_transactions, :login_transaction_return_path)

    alter table(:login_transactions) do
      modify :return_path, :string, size: 6, null: false
    end

    # Only fixed server-owned metadata changes; credentials, consumption and TTL
    # are preserved. No caller-provided redirect is carried forward.
    execute "UPDATE login_transactions SET return_path = '/admin' WHERE return_path = '/'"

    create constraint(:login_transactions, :login_transaction_return_path,
             check: "return_path = '/admin'"
           )
  end

  def down do
    drop constraint(:login_transactions, :login_transaction_return_path)
    execute "UPDATE login_transactions SET return_path = '/' WHERE return_path = '/admin'"

    alter table(:login_transactions) do
      modify :return_path, :string, size: 1, null: false
    end

    create constraint(:login_transactions, :login_transaction_return_path,
             check: "return_path = '/'"
           )
  end
end
