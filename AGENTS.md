# Repository Guidelines

# Scheduler Project

Magnum Detailing scheduling application.

## Stack

Frontend:
- React
- TypeScript
- Vite
- React Router

Backend:
- Elixir
- Phoenix
- Ecto
- PostgreSQL

## Architecture

- Phoenix provides the authoritative API and business logic.
- React consumes the Phoenix API.
- Database access and persistence logic belong in Ecto schemas, contexts, and repository modules.
- Phoenix controllers should remain thin.
- Do not duplicate server-authoritative pricing, duration, availability, or appointment rules in React.
- Preserve the current separation between frontend presentation concerns and backend business logic.

## Working Rules

- Preserve existing behavior unless the task explicitly requests a behavior change.
- Preserve the existing neon/synthwave visual design unless a task explicitly changes it.
- Prefer small, understandable, focused changes.
- Do not modify unrelated files.
- Inspect existing implementation and dependencies before editing.
- Reuse existing components, utilities, contexts, and helpers rather than duplicating logic.
- Do not add dependencies unless they are necessary.
- Run the relevant verification commands after making changes.
- Clearly explain significant architectural decisions.
- Never commit secrets, credentials, production database URLs, or secret keys.

## Project Structure

This repository contains a React/TypeScript frontend and a Phoenix JSON API backed by PostgreSQL.

### Frontend

- `frontend/src/pages/`: route-level React pages.
- `frontend/src/components/`: reusable React components.
- `frontend/src/types/`: shared TypeScript types.
- `frontend/src/utils/`: reusable pure frontend helpers.
- `frontend/src/assets/`: imported frontend images and assets.
- `frontend/e2e/`: permanent Playwright end-to-end tests.
- `frontend/src/App.tsx`: application shell, routing, and global navigation behavior.
- `frontend/src/main.tsx`: frontend entry point.

Follow `frontend/AGENTS.md` for frontend-specific implementation, testing, refactoring, and reporting rules.

### Backend

- `backend/lib/scheduler_api/`: application contexts, business logic, Ecto schemas, and repository-facing code.
- `backend/lib/scheduler_api_web/`: Phoenix controllers, JSON renderers, endpoint behavior, and routing.
- `backend/priv/repo/`: database migrations and seeds.
- `backend/config/`: Phoenix configuration.
- `backend/test/`: ExUnit tests and shared test helpers.
- `backend/scripts/`: project-specific backend utility scripts.

Follow `backend/AGENTS.md` for backend-specific implementation and testing rules.

### Repository

- `mise.toml` pins project runtime versions.
- Root-level instructions apply to the entire repository unless a more specific nested `AGENTS.md` provides additional guidance.

## Development Commands

Run commands from the appropriate directory.

Root:
- `mise install` installs the configured Elixir, Erlang, and Node versions.

Frontend:
- `npm ci` installs locked dependencies.
- `npm run dev` starts Vite.
- `npm run lint` runs ESLint.
- `npm run build` type-checks and builds the frontend.
- `npm run test:e2e` runs permanent Playwright end-to-end tests.
- `npm run preview` serves the production build locally.

Backend:
- `mix setup` installs dependencies, prepares the database, and seeds development data.
- `mix phx.server` starts the Phoenix API.
- `mix test` runs the ExUnit suite using the test database.
- `mix precommit` runs the backend precommit verification suite.

## Refactoring Rules

For refactor-only tasks:

- Preserve runtime behavior unless explicitly instructed otherwise.
- Do not change API contracts, routes, validation rules, accessibility behavior, timezone behavior, database semantics, CSS class names, or visual styling unless the task requires it.
- Prefer moving proven working code before simplifying or redesigning it.
- Make the smallest architectural change necessary to accomplish the requested refactor.
- Do not combine unrelated cleanup with a focused refactor.
- Keep domain-specific logic near the feature that owns it unless extraction provides clear reuse.
- Do not weaken tests or production safeguards to make a refactor pass.

## Verification

Use the verification requirements defined by the relevant nested `AGENTS.md`.

For changes spanning both frontend and backend, run the required verification suites for both sides.

Do not report a task as successful unless the requested checks were actually run.

If a check fails:
- Report the failure clearly.
- Distinguish failures introduced by the current work from pre-existing failures.
- Do not silently weaken tests, validation, accessibility, concurrency protection, or production behavior merely to obtain a passing result.

## Reporting

For significant changes, report:

- Files changed.
- Important architectural or behavioral changes.
- Whether existing runtime behavior changed.
- Verification commands run and their results.
- Any known failures, limitations, or follow-up work.

## Commit and Pull Request Guidelines

Use concise, action-oriented commit subjects that identify the area changed.

Pull requests should explain relevant behavior or architectural changes, list verification performed, and call out migrations or configuration changes when applicable.

Include screenshots when visual UI behavior changes.