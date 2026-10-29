
# Frontend Guidelines

Root instructions apply. Run npm commands from `frontend/`.

## Architecture and conventions

- `src/pages/`: route pages; `src/components/`: reusable UI; `src/types/`: shared types; `src/utils/`: pure helpers; `src/assets/`: imported assets.
- `App.tsx` owns routing and the application shell; `main.tsx` is the entry point. Preserve established routes unless explicitly changing routing.
- Use two-space indentation, single quotes, no semicolons, PascalCase components/types, camelCase functions/variables and `import type` for type-only imports.
- Reuse components, utilities and styles when beneficial. Keep feature-specific logic near its owner; avoid abstractions that add complexity without value.
- Preserve Magnum's established neon/synthwave design, responsive layouts and interactive states. Do not introduce new styling frameworks or CSS-in-JS without a demonstrated need.
- Use semantic HTML, accessible controls, labels, keyboard behavior and stable accessible selectors. Preserve native disabled behavior and validation relationships.

## Application boundaries

- Use same-origin relative `/api` requests. Phoenix is authoritative for service prices, durations, availability, booking rules and ownership.
- Keep anonymous service browsing and booking functional independently of staff authentication.
- Keep staff account controls and authentication errors out of public booking pages. Staff entry belongs to the `/admin` experience; `/auth/*` remains handled by Phoenix.
- Never expose Keycloak provider tokens, client secrets or authorization logic in React. Backend authentication does not imply admin authorization.
- Preserve loading, empty, error, retry and success states without introducing unrelated visual changes.

## Verification

During development, run focused checks appropriate to the change.

At checkpoints:
- Component/UI logic: `npm run test:component`, `npm run lint`, `npm run build`.
- Public booking/browser behavior: `npm run test:e2e`.
- Browser authentication: `npm run test:auth`, following the documented isolated runner requirements.
- Major frontend integrations: run all relevant suites once after the implementation stabilizes.

Do not repeat unchanged, successful checks. If a fix changes behavior, rerun affected checks.

For auth-related tasks, consult `../backend/AUTHENTICATION.md`. Real-provider verification cannot be replaced by mocked tests when the milestone requires live Keycloak behavior.

## Test isolation

- Component tests: `tests/`; anonymous Playwright: `e2e/`; real-provider browser tests: `auth-e2e/`.
- Browser tests use isolated test infrastructure and must not alter development appointments or user identities.
- Confirm required ports are available before running suites that launch servers. Never terminate user-owned development servers without authorization.
- Use accessible selectors and condition-based waits rather than brittle selectors or arbitrary sleeps.
- Choose booking dates relative to the clock, not permanently hardcoded dates.
- Fixtures must be repeatable, positively owned and cleaned after execution.
- Preserve booking success, validation, concurrency/conflict and confirmation coverage.
- Never weaken production security, business rules or assertions to make tests pass.

## Local commands

- `npm ci`: install locked dependencies.
- `npm run dev`: start Vite.
- `npm run preview`: serve the production build.

Prefer existing npm scripts over duplicate tooling.
