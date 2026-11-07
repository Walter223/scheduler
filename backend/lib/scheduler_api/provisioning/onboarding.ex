defmodule SchedulerApi.Provisioning.Onboarding.Proof do
  @moduledoc false
  use Ecto.Schema
  @derive {Inspect, only: [:id, :expires_at, :consumed_at]}
  schema "onboarding_proofs" do
    belongs_to :user, SchedulerApi.Accounts.User
    field :token_hash, :binary, redact: true
    field :binding_hash, :binary, redact: true
    field :csrf_state, :string, redact: true
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    field :request_hash, :binary
    field :result, :map
    timestamps(type: :utc_datetime)
  end
end

defmodule SchedulerApi.Provisioning.Onboarding do
  @moduledoc "Browser-bound OIDC signup proof. Never authorizes access to an existing tenant."
  import Ecto.Query
  alias SchedulerApi.{Repo, Provisioning, Authentication}
  alias SchedulerApi.Accounts.{User, SessionCSRF}
  alias SchedulerApi.Authentication.Credential
  alias SchedulerApi.Provisioning.Onboarding.Proof

  @doc false
  # Trusted validated signup callback only, not a controller identity/claims constructor.
  def issue_after_oidc(%User{id: id}, binding, opts \\ []) do
    with {:ok, hash} <- Credential.hash(binding), {:ok, now} <- Authentication.now(opts) do
      safe(fn ->
        user = lock_user!(id)
        limit!(:proof, to_string(id), 5, 3600, now)
        token = Credential.generate()
        {:ok, token_hash} = Credential.hash(Credential.reveal(token))

        Repo.insert!(
          %Proof{
            user_id: user.id,
            token_hash: token_hash,
            binding_hash: hash,
            csrf_state: SessionCSRF.new_state(),
            expires_at: DateTime.add(now, 600),
            inserted_at: now,
            updated_at: now
          },
          log: false
        )

        {:onboarding, token}
      end)
    end
  end

  def status(token, binding, opts \\ []) do
    safe(fn ->
      proof = proof!(token, binding, opts)
      lock_user!(proof.user_id)
      ensure_current!(proof, opts)
      if proof.consumed_at, do: Repo.rollback(:invalid_proof)
      %{csrf_token: SessionCSRF.masked_token(proof.csrf_state)}
    end)
  end

  def complete(token, binding, csrf, attrs, opts \\ []) do
    safe(fn ->
      proof = proof!(token, binding, opts)
      user = lock_user!(proof.user_id)
      ensure_current!(proof, opts)

      unless is_binary(csrf) and byte_size(csrf) <= 128 and
               SessionCSRF.valid?(proof.csrf_state, csrf),
             do: Repo.rollback(:invalid_csrf)

      # Canonical internal map from strictly allowlisted HTTP adapter; never credential/identity input.
      request_hash = :crypto.hash(:sha256, :erlang.term_to_binary(attrs, [:deterministic]))

      if proof.consumed_at do
        if proof.request_hash != request_hash, do: Repo.rollback(:replayed_proof)
        proof.result
      else
        {:ok, now} = Authentication.now(opts)
        limit!(:creation, to_string(user.id), 1, 86400, now)
        result = Provisioning.create_from_onboarding!(user, attrs, now)
        result = Map.new(result, fn {k, v} -> {Atom.to_string(k), v} end)

        Repo.update!(
          Ecto.Changeset.change(proof,
            consumed_at: now,
            request_hash: request_hash,
            result: result,
            updated_at: now
          ),
          log: false
        )

        result
      end
    end)
  end

  # Independent HTTP attempt budget commits even if subsequent validation/provisioning fails.
  def attempt(ip, opts \\ []) do
    with {:ok, now} <- Authentication.now(opts) do
      safe(fn -> limit!(:ip, ip, 20, 900, now) end)
    end
  end

  defp proof!(token, binding, opts) do
    with {:ok, th} <- Credential.hash(token),
         {:ok, bh} <- Credential.hash(binding),
         {:ok, now} <- Authentication.now(opts),
         %Proof{} = p <-
           Repo.one(
             from(p in Proof,
               where:
                 p.token_hash == ^th and
                   p.binding_hash == ^bh and p.expires_at > ^now,
               lock: "FOR UPDATE"
             ),
             log: false
           ) do
      p
    else
      _ -> Repo.rollback(:invalid_proof)
    end
  end

  defp ensure_current!(proof, opts) do
    # A lock wait must not allow a proof to outlive its deadline.
    with {:ok, now} <- Authentication.now(opts),
         :lt <- DateTime.compare(now, proof.expires_at) do
      :ok
    else
      _ -> Repo.rollback(:invalid_proof)
    end
  end

  defp lock_user!(id) do
    case Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE") do
      %User{status: status, email_verified: true} = user when status in [:active, :pending] ->
        user

      _ ->
        Repo.rollback(:ineligible_identity)
    end
  end

  defp limit!(kind, value, max, seconds, now) do
    key = :crypto.hash(:sha256, Atom.to_string(kind) <> ":" <> value)

    window =
      now
      |> DateTime.to_unix()
      |> div(seconds)
      |> Kernel.*(seconds)
      |> DateTime.from_unix!()
      |> DateTime.to_naive()

    %{rows: rows} =
      Repo.query!(
        """
        INSERT INTO signup_limits (key, \"window\", count) VALUES ($1,$2,1)
        ON CONFLICT (key) DO UPDATE SET \"window\"=EXCLUDED.\"window\",
          count=CASE WHEN signup_limits.\"window\"=EXCLUDED.\"window\" THEN signup_limits.count+1 ELSE 1 END
        WHERE signup_limits.\"window\"<>EXCLUDED.\"window\" OR signup_limits.count<$3
        RETURNING count
        """,
        [key, window, max],
        log: false
      )

    if rows == [], do: Repo.rollback(:rate_limited)
    :ok
  end

  defp safe(fun) do
    Repo.transaction(fun)
  rescue
    _ in [
      Postgrex.Error,
      Ecto.ConstraintError,
      Ecto.InvalidChangesetError,
      DBConnection.ConnectionError
    ] ->
      {:error, :operation_unavailable}
  end
end
