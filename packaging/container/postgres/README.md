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

The `com.orchard.postgres.plist` launchd service definition remains a future-mode
source artifact. Current PKG builds exclude it, and `postinstall` removes any
stale installed copy early, before role/TLS validation, so unsupported managed
Postgres state does not survive a failed install. The shipped
`orchard-managed-postgres` wrapper is only the guard described above.
