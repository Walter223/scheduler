# React + TypeScript + Vite

This template provides a minimal setup to get React working in Vite with HMR and some ESLint rules.

Currently, two official plugins are available:

- [@vitejs/plugin-react](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react) uses [Oxc](https://oxc.rs)
- [@vitejs/plugin-react-swc](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react-swc) uses [SWC](https://swc.rs/)

## React Compiler

The React Compiler is not enabled on this template because of its impact on dev & build performances. To add it, see [this documentation](https://react.dev/learn/react-compiler/installation).

## Expanding the ESLint configuration

If you are developing a production application, we recommend updating the configuration to enable type-aware lint rules:

```js
export default defineConfig([
  globalIgnores(['dist']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      // Other configs...

      // Remove tseslint.configs.recommended and replace with this
      tseslint.configs.recommendedTypeChecked,
      // Alternatively, use this for stricter rules
      tseslint.configs.strictTypeChecked,
      // Optionally, add this for stylistic rules
      tseslint.configs.stylisticTypeChecked,

      // Other configs...
    ],
    languageOptions: {
      parserOptions: {
        project: ['./tsconfig.node.json', './tsconfig.app.json'],
        tsconfigRootDir: import.meta.dirname,
      },
      // other options...
    },
  },
])

```

You can also install [eslint-plugin-react-x](https://github.com/Rel1cx/eslint-react/tree/main/packages/plugins/eslint-plugin-react-x) and [eslint-plugin-react-dom](https://github.com/Rel1cx/eslint-react/tree/main/packages/plugins/eslint-plugin-react-dom) for React-specific lint rules:

```js
// eslint.config.js
import reactX from 'eslint-plugin-react-x'
import reactDom from 'eslint-plugin-react-dom'

export default defineConfig([
  globalIgnores(['dist']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      // Other configs...
      // Enable lint rules for React
      reactX.configs['recommended-typescript'],
      // Enable lint rules for React DOM
      reactDom.configs.recommended,
    ],
    languageOptions: {
      parserOptions: {
        project: ['./tsconfig.node.json', './tsconfig.app.json'],
        tsconfigRootDir: import.meta.dirname,
      },
      // other options...
    },
  },
])

```

## Frontend testing

Run from `frontend/`:

```sh
npm ci
npm run test:component
npm run lint
npm run build
npx playwright install chromium
npm run test:e2e
```

### Component tests — presentation/error permutations

`npm run test:component` type-checks and runs Vitest + React Testing Library in
jsdom. `tests/BookingPage.test.tsx` mounts the actual BookingPage without a browser,
Phoenix or database. Only network responses are stubbed; production helpers and
component logic are not mocked or extracted for testing.

The 20 cases cover five catalog failure modes (HTTP, network, invalid JSON,
unexpected top-level data and malformed prices), loading/error presentation,
all nine known backend field labels, an unknown-field label, combined errors,
fallback messages and preservation of customer/vehicle form data. First/last
name length enforcement is independently covered by the real Phoenix controller
suite. One real browser/API field-rejection scenario remains below.

### Playwright — real workflows and catalog coverage

The 19 browser tests cover:

- All **nine** Basic/Mid/Supreme × Small/Medium/Large selections: displayed price,
  duration, booking-page handoff and scroll position. Expected values are explicit
  test expectations checked against the real source-controlled catalog.
- **Three completed bookings:** Basic/Small, Mid/Medium and Supreme/Large, using
  the real Phoenix API. Confirmation checks include saved details, Denver time
  from a Tokyo browser, changes made during submission, and Book Another Detail.
- A dedicated **320px** selection/accessibility case: exclusive selection across
  packages/sizes, toggling, disabled links, `aria-pressed`, and viewport overflow.
- Real slot-claimed recovery, all six fields' validation/accessibility and phone
  formatting, one real backend field rejection, both stale-availability paths,
  and Denver's minimum date from another browser timezone.

Shared setup directly opens the chosen booking URL for focused booking tests;
it no longer repeats the full Services selection assertions in every case.
Selection and normal bookings retain their own navigation coverage. The browser
count increased from 14 to 19 because package/size coverage was added; the seven
repeated catalog/name-error browser scenarios moved to component/API coverage.
Application behavior, CSS, routes and API contracts are unchanged.

Prerequisites: root `mise.toml` runtimes, local PostgreSQL with credentials from
`backend/config/test.exs`, and installed backend dependencies. Run
`npm run test:e2e:headed` for a visible browser or
`npm run test:e2e -- --repeat-each=3` to check repeatability. Test files are
TypeScript-checked before execution.

Playwright starts Phoenix on **4002** and Vite on **5174**, never reusing existing
servers. Normal development can continue on 4000/5173. Browser API requests are
forwarded from the app's fixed 4000 URL to the real isolated test API; the harness
only supplies the test frontend's CORS origin. Production booking/CORS rules are
unchanged. Conflict tests use a second real API client, not canned 422 responses.

### Isolated catalog fixtures and cleanup

The backend helper refuses to run unless `MIX_ENV=test`, `MIX_TEST_PARTITION=_e2e`
and the exact database **scheduler_api_test_e2e** are selected. Do not point it at
development data or share this partition between concurrent E2E runs.

Each test seeds the real `backend/priv/repo/seeds.exs` catalog into this partition,
with a description marker identifying fixture-owned packages. Dates use the next
open Denver date, not a fixed calendar date. IDs are obtained from the fixture;
prices/durations are independently asserted in browser tests. Update those
expectations intentionally when the real catalog changes.

Cleanup removes only marked fixture services, their prices/appointments and
associated sizes. It refuses foreign/shared references and refuses to overwrite
unmarked records with reserved Basic/Mid/Supreme or Small/Medium/Large names.
Setup cleans interrupted-run leftovers; teardown runs even after assertion
failure. The business/default shop remain foundation data. No database reset,
development writes, public test route or scheduling bypass is used. One worker
keeps the single-shop schedule and fixture lifecycle isolated.

Failed browser runs retain ignored screenshots/traces under `test-results/`.
Inspect with `npx playwright show-trace test-results/<test-folder>/trace.zip`.
