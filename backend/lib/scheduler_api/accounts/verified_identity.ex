defmodule SchedulerApi.Accounts.VerifiedIdentity do
  @moduledoc """
  Internal output contract for the FUTURE verified OIDC layer, not an HTTP DTO.

  Only construct after validating provider identity (issuer, subject, signature,
  audience, nonce and authentication time). Accounts accepts this struct, never
  raw params/claims; it does not verify OIDC. An opaque type is a code boundary,
  not cryptographic proof against other BEAM code. There is deliberately no
  constructor accepting a claims/params map.
  """
  @enforce_keys [:issuer, :subject, :email, :email_verified]
  @derive {Inspect, only: []}
  defstruct [
    :issuer,
    :subject,
    :email,
    :email_verified,
    :first_name,
    :last_name,
    :authenticated_at
  ]

  @opaque t :: %__MODULE__{
            issuer: String.t(),
            subject: String.t(),
            email: String.t(),
            email_verified: boolean(),
            first_name: String.t() | nil,
            last_name: String.t() | nil,
            authenticated_at: DateTime.t() | nil
          }
end
