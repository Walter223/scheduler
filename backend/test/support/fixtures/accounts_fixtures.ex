defmodule SchedulerApi.AccountsFixtures do
  @moduledoc "Isolated internal verified identities; never production seeds or HTTP login bypasses."
  alias SchedulerApi.Accounts
  alias SchedulerApi.Accounts.VerifiedIdentity

  def verified_identity_fixture(attrs \\ %{}) do
    struct!(
      VerifiedIdentity,
      Map.merge(
        %{
          issuer: "http://auth.magnum.test:8080/realms/magnum",
          subject: "opaque|subject/#{System.unique_integer([:positive])}",
          email: "staff@example.invalid",
          email_verified: true,
          first_name: "Example",
          last_name: "Staff"
        },
        attrs
      )
    )
  end

  def user_fixture(attrs \\ %{}, opts \\ []) do
    {:ok, user} = attrs |> verified_identity_fixture() |> Accounts.sync_verified_identity(opts)
    user
  end

  def active_user_fixture(attrs \\ %{}, opts \\ []) do
    user = user_fixture(attrs, opts)
    {:ok, user} = Accounts.set_user_status(user, :active, opts)
    user
  end
end
