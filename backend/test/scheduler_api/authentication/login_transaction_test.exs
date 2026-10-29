defmodule SchedulerApi.Authentication.LoginTransactionTest do
  use SchedulerApi.DataCase, async: true
  import SchedulerApi.OidcFixtures
  alias SchedulerApi.Authentication
  alias SchedulerApi.Authentication.{Credential, LoginTransaction}

  @now ~U[2026-10-27 18:00:00Z]

  test "four independent 256-bit credentials, hash-only state/binding, redacted inspect" do
    {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)
    t = Repo.get!(LoginTransaction, attempt.transaction.id)
    state = Credential.reveal(attempt.state)
    binding = Credential.reveal(attempt.browser_binding)
    values = [state, binding, t.nonce, t.pkce_verifier]
    assert MapSet.size(MapSet.new(values)) == 4

    for value <- values do
      assert byte_size(value) == 43
      assert {:ok, bytes} = Base.url_decode64(value, padding: false)
      assert byte_size(bytes) == 32
      refute inspect(attempt) =~ value
      refute inspect(t) =~ value
    end

    assert t.state_hash == :crypto.hash(:sha256, state)
    assert t.browser_binding_hash == :crypto.hash(:sha256, binding)
    refute Map.has_key?(Map.from_struct(t), :state)
    refute Map.has_key?(Map.from_struct(t), :browser_binding)
    assert DateTime.diff(t.expires_at, @now) == 600
    assert t.return_path == "/admin"
  end

  test "consumption clears both persisted secrets and rejects all replay" do
    {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)
    assert {:ok, material} = consume(attempt, @now)
    assert material.nonce == attempt.transaction.nonce
    assert material.pkce_verifier == attempt.transaction.pkce_verifier
    refute inspect(material) =~ material.nonce
    t = Repo.get!(LoginTransaction, attempt.transaction.id)
    assert t.consumed_at == @now
    assert is_nil(t.nonce)
    assert is_nil(t.pkce_verifier)
    assert {:error, :invalid_login_transaction} = consume(attempt, @now)
  end

  test "valid until strictly before the ten-minute boundary" do
    for {offset, result} <- [{599, :ok}, {600, :error}, {601, :error}] do
      {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)
      assert elem(consume(attempt, DateTime.add(@now, offset)), 0) == result
    end
  end

  test "wrong state/binding and malformed values do not burn the valid attempt" do
    {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)
    state = Credential.reveal(attempt.state)
    binding = Credential.reveal(attempt.browser_binding)
    other = nonce()
    assert {:error, _} = Authentication.consume_login_transaction(other, binding, now: @now)
    assert {:error, _} = Authentication.consume_login_transaction(state, other, now: @now)

    for bad <- [nil, %{}, "bad", String.duplicate("a", 100_000)] do
      assert {:error, _} = Authentication.consume_login_transaction(bad, binding, now: @now)
      assert {:error, _} = Authentication.consume_login_transaction(state, bad, now: @now)
    end

    assert {:ok, _} = consume(attempt, @now)
  end

  test "only admin return destination is approved" do
    for path <- [
          "/",
          "/admin/",
          "/admin?next=https://evil.invalid",
          "https://evil.invalid",
          "//evil.invalid",
          "/\\evil",
          "/%2f%2fevil",
          "/%ZZ",
          "/\n",
          "/contact",
          nil
        ] do
      assert {:error, :invalid_return_path} =
               Authentication.create_login_transaction(config(), return_path: path, now: @now)
    end

    assert {:error, :invalid_options} =
             Authentication.create_login_transaction(config(), now: "invalid")
  end

  test "database rejects a return destination outside the fixed admin allowlist" do
    {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)

    changeset =
      attempt.transaction
      |> Ecto.Changeset.change(return_path: "/")
      |> Ecto.Changeset.check_constraint(:return_path, name: :login_transaction_return_path)

    assert {:error, invalid} = Repo.update(changeset)
    assert Keyword.has_key?(invalid.errors, :return_path)
  end

  test "cleanup deletes only expired transactions" do
    {:ok, first} = Authentication.create_login_transaction(config(), now: @now)
    {:ok, second} = Authentication.create_login_transaction(config(), now: DateTime.add(@now, 1))

    assert {:ok, 1} =
             Authentication.delete_expired_login_transactions(now: DateTime.add(@now, 600))

    refute Repo.get(LoginTransaction, first.transaction.id)
    assert Repo.get(LoginTransaction, second.transaction.id)
  end

  test "DB rejects duplicate state and malformed digest lengths" do
    {:ok, attempt} = Authentication.create_login_transaction(config(), now: @now)

    for attrs <- [%{state_hash: <<1>>}, %{browser_binding_hash: <<1>>}, %{}] do
      duplicate =
        %{attempt.transaction | id: nil, browser_binding_hash: :crypto.strong_rand_bytes(32)}
        |> struct!(attrs)

      assert_raise Ecto.ConstraintError, fn -> Repo.insert!(duplicate, mode: :savepoint) end
    end
  end

  defp consume(attempt, now),
    do:
      Authentication.consume_login_transaction(
        Credential.reveal(attempt.state),
        Credential.reveal(attempt.browser_binding),
        now: now
      )
end
