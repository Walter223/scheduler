# Account identity and revocable session foundation

`SchedulerApi.Accounts` is an internal persistence context. It neither verifies
OIDC nor authenticates HTTP requests. No routes, cookies, plugs, browser login,
memberships, or authorization are implemented. The existing admin appointments
endpoint remains unauthenticated and development-only, not production-safe.

## Identity boundary

Only the validated OIDC adapter (see [AUTHENTICATION.md](AUTHENTICATION.md)) may construct
`SchedulerApi.Accounts.VerifiedIdentity`. There is no map/params constructor;
`Accounts.sync_verified_identity/2` rejects ordinary maps. This is a typed code
boundary, not proof against other trusted BEAM code constructing a struct. The
verifier must validate issuer, subject, signature, audience, nonce and
authentication-time requirements before handing over this type.

The exact `(keycloak_issuer, keycloak_subject)` pair uniquely identifies a local
user. Both are opaque, case-sensitive text, stored without trimming or UUID
assumptions. Each is bounded to 1024 bytes for safe PostgreSQL indexing. Email is
mutable cached contact data, not unique and never used to link identities.
Appointment customers remain completely separate; no customer data is backfilled.

Synchronization atomically inserts a **pending** user or updates only cached
profile/authentication fields on the existing identity. It preserves local ID,
creation timestamp, identity key and lifecycle status. No login can implicitly
activate a pending/suspended/deactivated account. `profile_synced_at` records the
injected current time; `last_authenticated_at` records supplied verified
`authenticated_at`, or the same current time when omitted. Times normalize to
UTC whole seconds.

`set_user_status/3` is a trusted internal lifecycle primitive, not an invitation
or authorization policy. Pending, suspended and deactivated users cannot use web
sessions. Setting any non-active status also durably revokes existing sessions,
so reactivation does not resurrect old credentials. Future activation policy
belongs to invitation/membership work.

## Session API

```elixir
{:ok, session, credential} = Accounts.create_session(active_verified_user)
# The credential wrapper redacts ordinary Inspect output.
raw_token = SchedulerApi.Accounts.SessionCredential.reveal(credential)
# Deliver only at the future browser credential boundary. NEVER log raw_token.
{:ok, session} = Accounts.get_session_by_token(raw_token)
{:ok, session} = Accounts.touch_session(session)
{:ok, session} = Accounts.revoke_session(session, :logout)
{:ok, count} = Accounts.revoke_all_sessions_for_user(active_verified_user, :security_event)
```

Only creation returns the inspect-redacted credential. It contains a canonical
unpadded Base64URL serialization of exactly 32 bytes from
`:crypto.strong_rand_bytes/1`. PostgreSQL stores only the 32-byte SHA-256 digest
of that **serialized string**, not of the decoded bytes. There is no raw-token
column, configurable weak random source, or provider-token storage. Explicitly
revealed strings must never be logged or included in errors. The wrapper does
not claim to prevent a caller deliberately copying/revealing a secret twice.

Lookup bounds input to 43 bytes, validates canonical decoding/re-encoding and
32 decoded bytes before any database query, then hashes the presented string.
Malformed, unknown, revoked, expired or blocked-account credentials return
`{:error, :invalid_session}`. Account-ineligible creation returns
`{:error, :ineligible_account}`. Invalid clocks/timeouts return
`{:error, :invalid_options}`. No raw credentials appear in these errors.

Every lookup joins the current user and requires **active + verified email**.
Session metadata or a stale supplied user cannot override persisted account
state. A valid session grants no business/shop/customer-data authorization.

Creation, lifecycle changes, touch and revocation use a consistent user-first,
session-second transaction/row-lock order. Mutations re-read authoritative state;
a stale touch cannot clear revocation or overwrite a more recent activity time.
Revocation reasons use a closed, non-sensitive enum: `logout`, `account_pending`,
`account_suspended`, `account_deactivated`, `security_event`, `recovery`,
`admin_sign_out`, `credential_compromise`, `session_rotation`. First revocation
time/reason are preserved; repeat revoke-all reports only newly revoked rows.

## Policy and time

Central defaults in `config/config.exs`, under `SchedulerApi.Accounts`:

- `idle_timeout_seconds`: 1800 (30 minutes)
- `absolute_lifetime_seconds`: 28800 (8 hours)

Internal create/touch calls may override these options for deterministic policy
tests. Positive integer values up to one year are accepted. All operations accept
`:now` for clock injection; it is not exposed through HTTP. There are no sleeps
in expiration tests.

Validity is strictly **before** both deadlines; equality or later is invalid.
Touch advances last-seen/idle expiry monotonically and caps idle expiry at the
original absolute deadline. It never extends absolute lifetime, even if policy
configuration changes. Lookup does not implicitly touch a session.

## Storage, retention and next milestone

The additive migration creates empty `users` and `web_sessions` tables only. It
uses existing bigint IDs/UTC timestamp conventions, unique identity/digest
indexes, account/revocation/expiry/digest-length checks, a user-session index and
an absolute-expiry index. The user foreign key restricts deletion rather than
cascading away session history. No operational tables or historical migrations
are changed. No real users are seeded.

Expired/revoked rows remain inert history. Retention duration, a safe purge
cutoff and eventual cleanup scheduling need a separate policy decision; no
destructive cleanup operation or background job is introduced yet.

No passwords, password hashes, reset secrets, OTP seeds, WebAuthn/passkey
credentials, or Keycloak access/refresh/ID tokens are stored. No OIDC dependency
is added. These primitives work with Keycloak stopped.

Next: recheck OIDCC versions/security/Req compatibility, then implement the BFF
protocol/session-delivery boundary. Before that work, decide same-origin/HTTPS
deployment, cookie/CSRF policy, provider-token encryption/storage, refresh and
logout/revocation behavior, and MFA/step-up proof. Membership authorization,
account activation policy and admin protection remain separate work; login must
never automatically grant appointment/customer access.

## Browser-session CSRF extension

Milestone B adds nullable `csrf_state` to web sessions without rewriting existing
rows. New sessions receive Plug-generated state; existing sessions initialize it
under lock on first status request. Only the masked form leaves Phoenix. Revocation
clears the state, and status requests do not renew idle expiry. No provider tokens
are stored. See [AUTHENTICATION.md](AUTHENTICATION.md) for the implemented browser
boundary; earlier next-milestone notes above describe the original Accounts stage.
