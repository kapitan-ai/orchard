# ADR: Controller-owned operations are the durable operator authority

## Status

Accepted on 2026-08-23 under issues #266 and #267.
This decision refines ADRs 0006 and 0011.

## Context

The current CLI mixes four responsibilities: portable client interaction, direct Controller and Repo authority, protected terminal custody, and macOS host lifecycle behavior.
The Controller release also loads CLI implementation to obtain a narrow local command handler.

Direct Repo operations prevent a portable remote CLI, duplicate authority across Console and CLI paths, and make transport, authorization, audit, leadership, confirmation, and secret-output behavior harder to keep coherent.
Moving commands to a network API without defining those security contracts would expand the remotely reachable management surface unsafely.

## Decision

An operation that authoritatively reads or mutates Controller-owned durable state SHALL execute inside the active Controller through authenticated, authorized, leader-aware, and audited Controller-owned domain operations.
Console and CLI clients SHALL invoke the same domain authority.

The portable CLI SHALL own argument parsing, client authentication, confirmation presentation, and output formatting.
After the applicable command-family migration, it MUST NOT require direct Ecto Repo access, Controller application modules, launchd, Darwin native helpers, or local Controller release evaluation for normal operator operations.
The Controller release MUST NOT load CLI implementation to obtain Controller authority after the local-handler migration.

Service-manager control, managed process fencing, environment materialization, local trust-store mutation, terminal custody, and host support collection belong to platform host tooling.
Mixed commands SHALL separate Controller-owned and host-local operations rather than grant one process both implicit authorities.

Retain a narrow locally authenticated Controller bootstrap or recovery channel only for operations that cannot yet use ordinary administrator credentials.
That channel SHALL invoke the same Controller-owned domain operations and MUST NOT become a general direct-Repo fallback.
`orchardctl cluster init` remains such a bootstrap operation under ADR 0011 unless a later accepted decision replaces it.

Migrate command families incrementally.
Before each migration, define its authentication, authorization scope, leader behavior, audit record, idempotency, confirmation and consequence acknowledgement, secret return semantics, and degraded-Controller behavior.
Current local Controller-runtime behavior remains the migration baseline until each replacement passes parity and failure-path acceptance.

## Consequences

Console and CLI converge on one Controller authority and one audit policy.
The CLI can become a portable remote client, and the Controller release can stop depending on CLI implementation.
Host lifecycle and terminal custody can move to platform-specific tooling without polluting the portable client.

The remotely reachable operator surface grows as command families migrate.
Each migration therefore requires security-led review and cannot be implemented as a mechanical HTTP wrapper around existing command modules.

## SPEC.md impact

Update required in §§2.5, 7.3, 7.4, and 11.9.
