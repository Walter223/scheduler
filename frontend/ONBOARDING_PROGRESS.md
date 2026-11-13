# Onboarding progress and navigation (UX-B1)

`onboardingProgress.ts` owns the presentation mapping; `OnboardingNavigation`
consumes it. Inputs are the last authorized server draft, never the unsaved editor,
visited tabs, Keycloak claims or browser storage. An unknown state is rejected by
SetupWorkspace. Phoenix remains the authorization and validation boundary.

## Completion contract

Six equally weighted stages: Business, Locations, Staff, Services, Branding, Review.
Percentage = round((completed + skipped) / 6 × 100). Skipped is displayed separately
from completed and means no team was planned when the persisted workflow passed
Staff. The API has no independent skip flag; historical intent beyond that fact is
not invented. Merely viewing a tab never changes the draft or percentage.

| Persisted state | Next required view | Resolved stages | Percent |
|---|---|---|---:|
| provisioning_complete | Business (review provisioned facts) | Business already exists | 17 |
| locations | Locations | Business | 17 |
| employees | Staff | Business, Locations | 33 |
| services_pricing | Services | Above + Staff (or skipped empty team) | 50 |
| branding | Branding | Above + Services | 67 |
| review | Review | Above + Branding | 83 |
| ready_to_publish | Review: Finish setup review | Review confirmation saved; not finished | 83 |
| completed | Review | All six resolved | 100 |

This is progress through validated **draft checkpoints**, not an assessment that a
live business is configured or bookable. Business is resolved because provisioning
already created it and its initial shop. Locations is resolved when the server
accepted progression to employees; Staff when it accepted services_pricing.
Services and Branding additionally respect server readiness flags: an incomplete
saved catalog/brand does not earn completion simply because a later checkpoint was
previously reached. If those flags invalidate an earlier checkpoint, navigation
returns to the earliest affected editor, saves repairs in the current workflow
state, then resumes. The client does not reproduce Phoenix validators. The API has
no separate current-locations readiness flag; location progress represents its
persisted validated checkpoint. Unsaved edits do not alter saved progress.

Only Staff supports the explicit “Continue without a team” action. Empty Services
can be saved/deferred, but is not skipped or complete; backend catalog requirements
remain enforced. Branding is required for forward progression. No new skip policy,
permission or domain transition was added.

## Navigation and persistence

On first load/resume select the persisted next-required editor. On later refreshes
inside the mounted workspace preserve its selected editor. A separate business
resets selection to its authorized checkpoint. All six views remain reachable;
selected/viewed and next-required states have separate labels. Back only navigates.
If viewing a different stage, Continue setup returns to the required stage without
writing. Save draft keeps the checkpoint; Save and continue requests exactly one
legal transition. Success selects the resulting required step only after receiving
the server response. Revision conflicts, uncertain identical retries, aborts and
session/tenant clearing retain the existing safeguards and transport.

Review confirmation sends confirm_review=true to the existing API, advancing review
to ready_to_publish. Finish setup review explicitly confirms the adjacent transition
to completed. Both are audited server-side. No endpoint, schema, migration or backend
policy changed. Completed drafts are read-only. The 100% message explicitly states
that the website is not published; no invitations, catalog, branding or mobile
booking are applied by these actions.

## Design and accessibility

The source reference is Magnum Detailing's actual animated navigation underline
in styles/navigation.css: cyan #00eaff → pink #ff2aa1, restrained glow and animated
width. No booking stepper was found in the current repository; the new component
reuses those actual visual primitives in Admin-scoped tokens without modifying
public styling. Fill uses a 350ms width transition; prefers-reduced-motion removes
it. Completed stages show checkmarks; skipped shows a dash; current viewing uses a
border/background, and required status is textual. Layout is six columns desktop,
three tablet and two phone, with native keyboard-operable buttons and visible focus.
The bar exposes min/max/value/value text; saved progress has a polite live announcement.
No navigation overlay or sticky obstruction was introduced. Existing forms are intact.

## Verification and captures

The real-Keycloak test `zzzzzzzz-ux-progress.spec.ts` uses the independent fixture
Business B, an authorized multi-business Owner, real protected APIs and UI controls.
It exercises all eight persisted states, empty-team skip, Back, refresh/resume,
keyboard Enter navigation, Review confirmation, finish, unpublished status and logout.
Every state is captured full-page and viewport at 1440/768/390, asserting no overflow.
Screenshots write to MAGNUM_SCREENSHOT_ARCHIVE/ux-b1-progress-bar/<timestamp>/;
locally the default is ~/projects/Magnum-Screenshots. CI without an explicit archive
uses its test output directory. No personal identities or development records are used.

Run focused acceptance from frontend:
`npm run test:auth -- --spec zzzzzzzz-ux-progress.spec.ts`.

Verification checkpoint: 143 component tests and 5 backend onboarding tests passed;
lint/build and diff checks passed. The new real-Keycloak progression test passed
independently. The full auth checkpoint passed 40/41; its only failure was an
ambiguous Business selector matching both the new step button and the business
combobox. That test now targets the combobox by role. The affected rerun (onboarding
API prerequisite, platform/business switching and progress journey) passed 4/4.
The full 41-test suite was not repeated after the selector correction. Owned fixtures
and services were cleaned; user-owned servers and development records were preserved.

Final captures (48 PNGs, eight states × three widths × full/viewport):
`/Users/TravisBigelow/projects/Magnum-Screenshots/ux-b1-progress-bar/2026-11-12T04-31-51.778Z/`.
Images were reviewed for desktop/tablet/mobile layout; no document overflow was
observed. Existing long editor forms and guided-assistant presentation remain for
subsequent UX milestones; no claim of full accessibility certification is made.
