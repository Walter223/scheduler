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

## Booking E2E tests

The permanent Playwright suite covers successful booking/confirmation and the
slot-claimed recovery flow against the real React app, Phoenix API, and PostgreSQL.
The race test uses a second API client to book the visible slot before the browser
submits; it does not mock an error response.

Prerequisites: the runtimes in root `mise.toml`, local PostgreSQL running with the
credentials in `backend/config/test.exs`, and backend dependencies installed
(`cd backend && mix deps.get` from the repository root).

From `frontend/`:

```sh
npm ci
npx playwright install chromium
npm run test:e2e
```

For a visible browser, use `npm run test:e2e:headed`. To check repeatability, run
`npm run test:e2e -- --repeat-each=3`. The E2E command also type-checks its test files.

Playwright starts and stops its own Phoenix server on port **4002** and Vite on
**5174**. Both ports must be free; existing servers are never reused. Your regular
development servers may continue on 4000/5173.

The Phoenix server uses `MIX_ENV=test` and `MIX_TEST_PARTITION=_e2e`, creating and
migrating **scheduler_api_test_e2e** using the existing test configuration. Browser
API requests are forwarded by the test harness from the app's fixed port 4000 URL
to this test server. Responses and status codes come from Phoenix; the harness
only supplies the test frontend's CORS origin. Production CORS and booking rules
are unchanged, and no browser API request reaches the development database.

Each test creates its own named E2E service, vehicle size, and price, and chooses
the next open date using Denver time. Cleanup deletes only those fixtures and their
appointments, even after an assertion failure. Setup removes leftovers from an
interrupted run. Tests run with one worker because the schedule is a shared resource;
reserve this database partition for one E2E run at a time. The ordinary backend
test database and development data are untouched.

Failed runs retain screenshots and traces under ignored `test-results/`. Inspect
a trace with `npx playwright show-trace test-results/<test-folder>/trace.zip`.
The backend test helper is `backend/scripts/e2e.exs`; it refuses to run outside
the dedicated test partition and adds no production routes or test bypasses.
