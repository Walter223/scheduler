# Frontend Guidelines

React + TypeScript + Vite frontend for Magnum Detailing.

## Architecture

- Pages belong under `src/pages/`.
- Reusable UI belongs under `src/components/`.
- Shared TypeScript types belong under `src/types/`.
- Pure reusable helpers belong under `src/utils/`.
- Preserve the existing neon/synthwave design unless a task explicitly changes it.
- Phoenix remains authoritative for pricing, duration, availability, and appointment creation.
- Do not duplicate backend business rules in React.

## Working Rules

- Prefer small, focused changes.
- Do not modify unrelated files.
- Preserve existing behavior unless the task explicitly requests a behavior change.
- Reuse existing components, types, and utilities rather than duplicating them.
- Inspect existing implementation and dependencies before editing.
- Do not add dependencies unless necessary.

## Refactoring Rules

For refactor-only tasks:

- Preserve runtime behavior.
- Do not change API contracts, routes, validation rules, accessibility behavior,
  timezone behavior, CSS class names, or styling unless explicitly requested.
- Prefer moving working code verbatim before simplifying or redesigning it.
- Make the smallest change necessary for the requested refactor.
- Do not combine architectural cleanup with unrelated behavior changes.
- Keep domain-specific logic near its feature unless there is clear reuse.

## TypeScript / React Style

- Use two-space indentation.
- Use single quotes.
- Omit semicolons.
- Use PascalCase for components and types.
- Use camelCase for functions and variables.
- Prefer `import type` for type-only imports.
- Prefer accessible selectors, labels, roles, and semantic HTML.
- Preserve existing React Router URLs unless explicitly changing routing.

## UI and Styling

- Prefer reusable components for repeated UI patterns such as buttons, cards,
  form controls, panels, and navigation elements.
- Preserve existing visual behavior when extracting reusable components.
- Avoid duplicating CSS for visually equivalent components.
- Prefer shared style primitives or component classes over increasingly specific
  page-level selectors when the same pattern appears in multiple places.
- Keep responsive behavior intact during styling refactors.
- Do not introduce a new styling framework or CSS-in-JS library unless explicitly requested.
- Preserve existing neon effects, spacing, typography, hover states, focus states,
  disabled states, and responsive behavior unless the task explicitly changes them.

## Frontend Verification

Run frontend verification commands from `frontend/`.

After frontend code changes, run:

1. `npm run test:component`
2. `npm run lint`
3. `npm run build`
4. `npm run test:e2e`

Focused checks may be used while developing, but all four should pass before
reporting significant frontend work as complete.

Do not report success unless the requested checks were actually run.

If a check fails:

- Report the failure clearly.
- Distinguish failures introduced by the current change from pre-existing failures.
- Do not weaken tests, validation, accessibility, or production behavior simply
  to make checks pass.

## E2E Testing

- Playwright is the permanent frontend E2E test framework.
- Prefer accessible selectors over brittle CSS selectors.
- Do not use arbitrary sleeps.
- E2E tests must not consume or depend on development appointment data.
- Use the dedicated Phoenix E2E test database and fixture cleanup.
- Avoid hardcoded dates that will eventually become invalid.
- Preserve customer-visible race-condition behavior and confirmation behavior.
- Core booking-flow E2E tests should exercise the real Phoenix API rather than
  replacing appointment creation or conflict handling with mocked responses.
- New E2E tests must clean up any fixtures they create and remain repeatable.

## Reporting

After significant frontend work, report:

1. Files changed
2. Important code/types/helpers moved or added
3. Behavioral changes, if any
4. Lint result
5. Build result
6. E2E result
