# Managed Postgres container assets

This path is reserved for future Managed Database Mode assets described in
`../../SPEC.md`. It is not part of the current packaged install path.

Managed Postgres is not available in current builds.
Controller-bearing app installs require an external PostgreSQL server.
The shared payload includes only an operator-safe `orchard-managed-postgres` guard and excludes the Postgres LaunchDaemon.
See `../README.md` and `postgres/README.md`.

Future assets here should target Apple-Silicon-compatible local
containerization, not Docker-first operator assumptions.
