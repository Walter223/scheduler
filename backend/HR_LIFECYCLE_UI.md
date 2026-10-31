# Termination and rehire UI — 5C-2B

Existing `hr_manage` capabilities expose termination on the latest active profile,
and rehire on the latest ended profile or Former Employees card. Shop Manager
rosters and explicit historical period views remain read-only. Classification is
never proof of authority. Business Owners/Managers must still pass the existing
record-specific domain policy; a generic business capability does not override
current/historical Owner protection or last-eligible-Owner safeguards.

## Separate confirmations and requests

Terminate Employee requires a native accessible modal confirmation explaining:
employment ends in this business; future jobs are unassigned without changing other
team members; future shifts are cancelled; active shop assignments end; linked
business access/grants are revoked; unrelated businesses and complete historical
records are retained. Work already in progress, incompatible dates and ownership
safeguards may block the operation. React sends only `{}` to the existing exact
employee/period `/terminate` endpoint. It does not implement work cleanup or resolve
conflicts locally. Success is reported only after the backend accepts the operation;
rejected/rolled-back writes never produce a success message. The response must
confirm the exact requested stable/period identity and ended status; already-ended
responses are reported explicitly as no-ops, not new offboarding.

Rehire Employee is a separate confirmation on the stable employee identity and
latest ended period. It explains that a new period restores no memberships, grants,
account access, rates, shops, shifts, jobs or private contacts. It sends only
`starts_on` to the existing `/rehire` endpoint. Native input minimum and submit
validation require a calendar date AFTER the recorded termination date; inclusive
same-day end/rehire remains unsupported. Date-only UTC arithmetic avoids browser
locale/DST shifts. Backend validation remains authoritative.

Termination success switches to/refetches Former Employees and the latest profile.
Rehire success refreshes Active Employees and the latest profile/timeline. A
future-effective rehire does not appear in Active Employees until its effective
date: the success message explains this, and the profile retains explicit start
and period information. Previous periods remain separate authorized HR history,
never aliases for the new current period. Rehire performs no account invitation,
linking, membership activation, role restoration or compensation setup.

## Security and state

Existing opaque HttpOnly session, ephemeral session-bound CSRF/header, browser
Origin, strict payload allowlists, synchronous duplicate-submit lock, disabled
pending forms and authorized re-read behavior are reused from 5C-2A. No bearer or
provider tokens enter React. Business/shop context teardown aborts forms and
ignores late responses; it cannot undo a server commit already in progress.
401/403 clears private views. Work/date/last-Owner/legacy-offboarding/stale-period
conflicts have bounded useful messages, without SQL, private audit or identity
information. Authorization denial remains generic rather than revealing protected
role/classification history. Unexpected/network errors ask for refresh before retry;
there are no automatic POST retries or optimistic lifecycle changes.

## Actual verification boundaries

Component tests cover confirmation content, exact empty termination payload,
rehire identity/period path and date-only payload, inclusive date rejection,
blocker handling, duplicate termination and context-teardown late completion.
Existing backend HTTP/domain tests cover two distinct employments/businesses with
one stale cookie, Owner history and last-Owner protection, multiple shops, future
work/team preservation, audit rollback and independent-connection races.

Real-Keycloak acceptance adds Owner and Manager termination/rehire (including HR
classification), Former/Active visibility, retained stable identity with a new
period, historical/current contact separation, no restored shops, mobile keyboard
confirmation and a Business Manager's blocked attempt against Owner-classified
employment without an Owner grant. The isolated runner verifies retained ended
roots/new active periods, unlinked identity/contact isolation, zero new-period shop
assignments and unchanged grant counts before deleting positively owned fixtures.

These browser cases use disposable unlinked employees. Linked-user/two-business
revocation, future multi-Detailer cleanup and fault-injected rollback are backend
HTTP/domain evidence, not newly claimed real-browser lifecycle coverage. Exhaustive
screen-reader testing and simultaneous multi-user browser lifecycle races remain
separate acceptance gaps. No backend lifecycle policy, migrations or development
data changes are introduced.
