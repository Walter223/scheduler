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

- Phoenix provides the API.
- React consumes the Phoenix API.
- Database logic belongs in Ecto/context modules.
- Controllers should remain thin.
- Do not duplicate pricing or duration logic in React.

## Working rules

- Preserve the existing neon/synthwave visual design.
- Do not rewrite unrelated files.
- Prefer small, understandable changes.
- Run relevant tests and compile checks after changes.
- Explain significant architectural decisions.
- Do not add dependencies unless they are necessary.
- Never commit secrets or credentials.

## Project Structure & Module Organization

This scheduler pairs a React/TypeScript frontend with a Phoenix JSON API and PostgreSQL.

- `frontend/src/`: components and routes in `App.tsx`, entry point in `main.tsx`, CSS, and imported images in `assets/`. `frontend/public/` holds public assets.
- `backend/lib/scheduler_api/`: catalog logic, Ecto schemas, and repository code. `backend/lib/scheduler_api_web/` holds controllers, JSON rendering, and routing.
- `backend/priv/repo/`: timestamped migrations and seeds. `backend/config/` contains environment configuration; `backend/test/` contains tests and shared helpers.
- `mise.toml` pins runtime versions. Follow `backend/AGENTS.md` for backend-specific instructions.

## Build, Test, and Development Commands

Run commands from the indicated directory:

- Root: `mise install` installs the configured Elixir, Erlang, and Node versions.
- `frontend/`: `npm ci` installs locked dependencies; `npm run dev` starts Vite; `npm run build` type-checks and builds; `npm run lint` runs ESLint; `npm run preview` serves the build locally.
- `backend/`: `mix setup` installs dependencies, creates/migrates the database, and seeds data. Start PostgreSQL first.
- `backend/`: `mix phx.server` starts the API on port 4000; `mix test` prepares the test database and runs ExUnit.
- `backend/`: `mix precommit` compiles with warnings as errors, removes unused dependency locks, formats, and tests.

## Coding Style & Naming Conventions

Use two-space indentation. Match frontend single quotes and omitted semicolons; use PascalCase component/type names and camelCase functions/variables. ESLint checks TypeScript, React Hooks, and React Refresh rules.

Format Elixir with `mix format`; use snake_case filenames/functions and PascalCase modules under `SchedulerApi` or `SchedulerApiWeb`. Generate migrations with `mix ecto.gen.migration descriptive_name`.

## Testing Guidelines

Backend tests use ExUnit and Ecto SQL Sandbox. Name files `*_test.exs`, mirror module paths, and reuse `test/support/` fixtures and case helpers. Run a focused suite with `mix test test/scheduler_api/catalog_test.exs`. No coverage threshold or frontend test runner is configured. Validate UI changes with lint/build and manually check service selection and contact-page navigation.

## Commit & Pull Request Guidelines

History uses informal descriptive commits without a consistent prefix convention. Write concise, action-oriented subjects identifying the changed area. PRs should explain behavior changes, link related issues when applicable, list validation, and include screenshots for UI changes. Highlight migrations and configuration changes. Keep production `DATABASE_URL` and `SECRET_KEY_BASE` values out of commits.
