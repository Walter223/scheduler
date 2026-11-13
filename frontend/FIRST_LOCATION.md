# First Location onboarding (UX-C1)

The Locations editor asks “Where will you serve customers?” and presents native
radio-card choices: At our shop, We travel to customers, Both. The first location
uses the provisioned shop's name/timezone and existing_shop_id. Technical keys and
shop IDs are never editable. An empty saved location list receives an in-memory
suggested reference to the first authorized applied shop; it is marked Unsaved and
only enters the draft on explicit Save. No shop-create endpoint is called. Existing
nonempty location drafts keep their keys, inheritance and shop references unchanged.

This is a **private proposal editor**, not an operational shop editor. Changing a
name/address/mode here does not rename a live shop, alter booking capacity, publish
mobile services, send invitations or create employment. The existing progress shell
continues to derive completion from server-saved checkpoints. Save draft supports
partial address/mobile details; Save and continue requires the fields needed by the
existing server's completion contract. Switching tabs does not save or advance.

## Supported persisted controls

| UI | Existing draft field | Behavior |
|---|---|---|
| Location name | name | Suggested from the existing shop; editable in draft |
| At our shop / We travel / Both | operating_model | in_shop / mobile / both |
| Shop address | address | Shown for physical/combined service |
| Dispatch / base address | address | Required for mobile completion by current backend policy |
| Location timezone | timezone | Suggested from shop; searchable existing server timezone catalog |
| Cities or service areas | mobile.service_areas | One named area per line; no radius or geographic coverage guarantee |
| Where does your team start? | mobile.dispatch_source | this_location or location_key |
| Starting location | mobile.dispatch_location_key | Existing stable draft location key |
| Extra travel time | mobile.travel_buffer_minutes | Whole minutes 0–240; planning only |
| Shared settings | defaults.timezone / operating_model | Advanced disclosure; local overrides remain explicit |

Mobile controls open for mobile/combined modes. Switching to physical retains local
mobile values in an expandable “saved for later” section instead of discarding them.
Existing shared mobile defaults remain preserved and are resolved in the local
mobile editor. Local changes create explicit overrides. Empty area lines are ignored
on save while normal multiline typing is retained. Additional proposed locations
remain supported; existing shops can be linked from the advanced disclosure. Their
IDs/keys remain stable, and removing a proposed location does not delete a shop.
Referenced-location removal is still rejected server-side until dependent drafts are
resolved. Existing-shop proposals cannot be removed by the ordinary editor action.

## Validation, state and privacy

Client feedback checks required names, supported timezone suggestions when loaded,
mode, forward-progression address, mobile areas, starting point and whole travel
minutes. It is assistance, not authorization or a replacement for Phoenix validation.
Required errors sit beside the field; the first invalid input receives focus.
Server errors receive a location-specific summary rather than the old cross-stage
checklist. The current endpoint does not return structured field error paths, so
unknown server rejections are not falsely attributed to one field. If timezone
suggestions cannot load, the server still validates exact identifiers.

The parent retains one proposal and the existing explicit-save lifecycle. No autosave
was introduced. Revisions, request IDs, uncertain identical retries, 409 recovery,
CSRF/session checks and business-switch abort/late-response protection are retained.
Back/Next and radio choices preserve in-memory entered values. Reload resumes only
confirmed server saves. The guide remains available after the editor/actions so it
does not displace the first-location task. No private fields/tokens enter browser
storage. No APIs, migrations or domain authorization changes were needed.

## Verification

New isolated real-Keycloak acceptance: `npm run test:auth -- --spec zzzzzzzzy-location.spec.ts`.
It checks field errors, unchanged progress before valid save, all service modes,
reloading, Back/Next, persisted mobile values and unchanged applied shop records.
It uses disposable business/Owner fixtures; it never uses personal development data.
Existing workspace and progress tests now use the new accessible location labels.
The full suite includes the prior 41 tests plus this new scenario (42 total).

Screenshots are written directly to MAGNUM_SCREENSHOT_ARCHIVE/ux-c1-first-location/
<timestamp>/; the local default is ~/projects/Magnum-Screenshots. Four states
(required address, physical, saved combined, saved mobile) are captured at 1440,
768 and 390px. CI without an explicit archive uses test output instead.

Limits: no distance radii, map/geocoding, active mobile booking or live shop changes.
Mobile-only plans still require a base address. Cross-section validation errors and
referenced-location conflicts may require reviewing other draft sections; the editor
does not silently delete those references. Individual later-stage forms are unchanged.

Verification checkpoint: 145 component tests, 10 backend onboarding/location tests,
lint and production build passed. The complete real-Keycloak suite passed 42/42,
including the prior 41 tests after the UX-B1 selector correction. A final focused
location browser run also passed after the scoped timezone-help styling refinement.
The initial new-test failures were harness synchronization/selector issues (checking
Begin setup before load, and selecting a combobox through an overly exact label
locator); they were fixed without retries, sleeps or weaker assertions.

Final responsive captures (12 PNGs):
`/Users/TravisBigelow/projects/Magnum-Screenshots/ux-c1-first-location/2026-11-13T05-54-23.304Z/`.
Files: physical-required-address-{1440,768,390}.png, physical-{1440,768,390}.png,
combined-saved-{1440,768,390}.png, mobile-saved-{1440,768,390}.png.
Full-page desktop/tablet/mobile images were inspected; no horizontal overflow was
observed. Test fixtures/processes are cleaned. Owner development data and servers
were preserved; there are no backend changes or development migrations.
