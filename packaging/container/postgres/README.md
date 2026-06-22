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
- Automatic bootstrap during `postinstall`

## Current state

The `com.orchard.postgres.plist` launchd service definition exists but should
**not** be bootstrapped until a functional `orchard-managed-postgres` binary is
available. The installer does not bootstrap it by default.
