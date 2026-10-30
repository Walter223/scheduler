# Magnum

**A multi-tenant platform for running modern detailing businesses.**

Magnum brings customer booking, shop scheduling, employee management, and day-to-day operations into one system. It is designed for a single detailing shop today and for businesses operating multiple locations and crews as they grow—with a foundation that can eventually accommodate larger jobs such as semis, boats, and aircraft.

> **Project status:** Active development. Customer-facing booking functionality and substantial backend administration capabilities exist; the full Admin Command Center, payments, and Google Calendar integration are not yet complete. Magnum is **not production-ready**.

## What Magnum does

### Customer booking

- Presents detailing services, vehicle-size pricing, and estimated durations.
- Provides appointment availability and customer booking workflows.
- Protects bookings against conflicting reservations, including concurrent requests.
- Uses explicit shop context and shop-local scheduling rules.

### Business and shop operations

- Models separate businesses and their shops, with business- and shop-scoped permissions.
- Supports employees working at multiple shops and, independently, for multiple businesses.
- Maintains employee shifts, appointment assignments, and multi-Detailer crews.
- Allows an optional Lead Detailer per appointment.
- Prevents overlapping employee assignments and enforces the current shift-coverage policy.
- Retains auditable assignment and schedule history.

### Employee and HR management

- Tracks employee records, contact information, classification, and shop assignments.
- Supports restricted, effective-dated compensation records.
- Implements audited hiring, HR edits, termination, and rehire workflows.
- Preserves former employees, historical pay, prior work, and employment periods instead of deleting them.
- Creates a new employment period on rehire without restoring previous permissions, pay, or assignments automatically.

### Secure administration APIs

- Provides protected HR directory, employment-history, HR mutation, shift, and appointment-team HTTP APIs.
- Enforces business/shop authorization in the backend; UI controls are not the security boundary.
- Uses session authentication, CSRF/origin protections for writes, scoped queries, bounded inputs, and explicit response fields.
- Keeps historical employee self-service data isolated from newer employment periods.

## Architecture

| Layer | Technology | Responsibility |
| --- | --- | --- |
| Frontend | React, TypeScript, Vite | Customer experience; future Admin Command Center |
| Backend | Elixir, Phoenix, Ecto | Booking workflows, business rules, REST APIs, authorization |
| Database | PostgreSQL | Tenant relationships, transactional integrity, scheduling constraints, history |
| Authentication | Keycloak / OIDC | Identity provider; Phoenix manages server-side sessions |
| Testing | ExUnit, Playwright | Backend regression, concurrency, browser and API checks |

**Design principles:** Explicit tenant boundaries, least-privilege access, database-enforced integrity, durable audit history, and keeping sensitive business rules out of the frontend.

### Repository layout

```text
backend/       Phoenix API, domain contexts, database migrations, backend docs
frontend/      React/TypeScript frontend and Playwright tests
scripts/       Development checks and smoke-test helpers
docs/          Cross-cutting product and security requirements
AGENTS.md      Repository conventions and coding-agent guidance
```

## Getting started

### Prerequisites

You'll need compatible versions of Elixir/Erlang, PostgreSQL, Node.js, and the local Keycloak configuration. Consult the repository's environment and authentication documentation before starting services. Do not commit secrets or local credentials.

### Development workflow

Start the configured database and Keycloak services, then run the Phoenix backend and Vite frontend using the project's existing configuration. **Verify environment setup and exact start commands against the checked-in project files** before treating this section as a copy/paste installation guide.

Useful verification commands from the repository root:

```bash
./scripts/check-fast.sh   # Formatting/lint and quick checks
./scripts/check-full.sh   # Broader backend, frontend, and Playwright checks
./scripts/dev-smoke.sh    # Read-only local backend/frontend smoke test
```

Backend verification:

```bash
cd backend
mix precommit
```

Apply migrations to the **intended** local database only after checking its configuration:

```bash
cd backend
mix ecto.migrations
mix ecto.migrate
```

> Some test suites manage isolated databases and ports. Read the scripts before running checks against shared or valuable environments.

## Access model

Magnum separates **employment classification** from **application permissions**. Business Owners, Business Managers, Shop Managers, and Employees have different authorized capabilities. Permissions must come from a complete qualifying grant for the requested action and business/shop scope; grants cannot be combined to invent broader access.

An employee may work for more than one business. Removing access to one employer must not remove the same person's valid access to a different employer. Termination preserves historical records for authorized HR users but revokes the terminated business's access. Rehire creates a fresh employment period with no automatic restoration of old access.

## Development status and roadmap

**Implemented foundations**

- Customer services, availability, and booking logic.
- Multi-business and multi-shop data model and authorization.
- Keycloak-backed authentication and protected server-side sessions.
- Employee records, compensation rules, shifts, teams, and employment history.
- Audited HR/offboarding/rehire domain workflows.
- Protected HR and scheduling HTTP APIs.
- Backend and browser/API regression-test infrastructure.

**Upcoming work**

1. Protected compensation and role-management APIs.
2. Admin Command Center: dashboard, business/shop switching, employee directory, Former Employees, appointments, crews, shifts, and management screens.
3. Google Calendar appointment synchronization, scoped per connected shop.
4. Payments, customer communications, additional workflows, reporting, and production/SaaS readiness.
5. Performance testing and observability, including Grafana/k6, at the end of the current roadmap.

The roadmap is directional; features listed as upcoming should not be considered available today.

## Documentation

- [Repository guidance](AGENTS.md)
- [Employment model](backend/EMPLOYMENT.md)
- [Employment/access scenarios](docs/employment-access-scenarios.md)
- [Work shifts](backend/WORK_SHIFTS.md)
- [Appointment teams](backend/APPOINTMENT_ASSIGNMENTS.md)
- [Offboarding](backend/OFFBOARDING.md)
- [Rehire](backend/REHIRE.md)
- [HR read API](backend/HR_READ_API.md)
- [HR write API](backend/HR_WRITE_API.md)
- [Scheduling API](backend/SCHEDULING_API.md)

## Working on Magnum

Read [AGENTS.md](AGENTS.md) before making changes. Prefer scoped milestones, existing authorized domain entry points, additive/data-preserving migrations, explicit tests, and focused commits. Never bypass authorization or rewrite historical employment and audit data for convenience.

---

**Magnum's goal:** Make the operational side of detailing—from booking a car to coordinating a multi-person specialty job—simpler, more reliable, and easier to scale.
