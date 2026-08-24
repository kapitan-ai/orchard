# Managed Postgres (unavailable in current builds)

> **Status:** Managed Postgres is not available in this build. The
> `orchard-managed-postgres` wrapper is an operator-safe placeholder: help
> invocations print the current external PostgreSQL setup path, while
> operational invocations exit non-zero without starting or mutating anything.
> The packaged controller currently requires an **external PostgreSQL** server.

## Intended future responsibilities

- Local loopback-only Postgres runtime
- Persistent data under `/Library/Application Support/Orchard/data/`
- Health checks via `pg_isready`
- Explicit app-lifecycle bootstrap

## Current state

The `com.orchard.postgres.plist` launchd service definition remains a future-mode source artifact.
Current payload builds exclude it.
The app lifecycle removes only launchd services it owns, and the shipped `orchard-managed-postgres` wrapper remains the guard described above.
