
# Repository Guidelines

Magnum Detailing is a multi-tenant detailing SaaS with a Phoenix/Ecto/PostgreSQL backend and React/TypeScript/Vite frontend. Runtime versions are pinned in `mise.toml`; use `mise install` when needed.

## Working rules

- Check Git status and inspect relevant code/tests before editing. Keep changes focused and preserve unrelated work.
- Reuse existing patterns and dependencies. Avoid speculative abstractions, unrelated refactors and unnecessary dependency updates.
- For behavior-preserving refactors, retain API contracts, routes, validation, accessibility, timezone/database semantics and visuals unless the task explicitly requests changes.
- Phoenix owns pricing, duration, availability, appointment rules, tenant ownership and authorization. React presents server-authoritative data.
- Preserve business/shop isolation. Authentication never grants business/shop authorization; hidden routes are not access controls.
- Never expose or commit credentials, secrets, provider tokens or private keys. Do not reset databases, delete persistent data, stop user-owned servers or reset Keycloak without authorization.
- Do not commit, push or deploy unless requested.

## Task-specific guidance

- Backend work: follow `backend/AGENTS.md`.
- Frontend work: follow `frontend/AGENTS.md`.
- Consult specialized documentation only when relevant to the affected feature. The nested guides identify the applicable references.
- Inspect only the code and documentation needed for the task; expand investigation when dependencies or failures require it.

## Verification

- During implementation, run focused checks for affected behavior.
- At implementation checkpoints, run the affected regression suites. Reserve full cross-stack regression for integration milestones or explicit requests.
- Do not rerun successful, unchanged checks without a reason.
- Documentation-only changes need diff/link checks, not application tests.
- Run documented, isolated, non-destructive tests without repeatedly requesting approval when their prerequisites are satisfied.
- Before tests that start servers or alter database state, verify isolation and check for occupied ports. Preserve user-owned services and development data.
- Fix failures caused by the change without weakening security, validation or test assertions. Distinguish pre-existing failures from regressions.

## Reporting

Report concisely:
- What changed and why.
- Significant behavior, architecture or configuration impacts.
- Checks actually run and their results.
- Remaining failures, blockers and relevant risks.

Use action-oriented commit subjects. PRs should describe the final changes, verification and migration/configuration implications; include screenshots for meaningful visual changes.
