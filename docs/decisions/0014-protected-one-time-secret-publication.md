# ADR: Protected file-backed One-time Secret Output uses two commit points

## Status

Accepted.

## Context

`SPEC.md` §7.4.4 requires file-backed One-time Secret Output after a successful credential or provisioning commit.
`SPEC.md` §11.9 applies that pattern to `orchardctl cluster init`.
Creating the operator-selected final inode before reducing its mode allows a local reader to retain a descriptor and later observe plaintext written through the same inode.
Treating a nonzero CLI result as proof of rollback is also incorrect after the database credential commit because filesystem publication and cleanup can fail independently.
POSIX file operations may fail without erasing or durably removing previously written bytes.

## Decision

File-backed secret publication uses two independent commit points.
The authority commit makes the credential active and is not rolled back by later filesystem failure.
The publication commit is confirmed only after an owner-only staging namespace exists, the staged inode is verified as mode `0600`, the complete payload is written and file-synced through its bound descriptor, the descriptor is closed, the inode is installed at the final path without clobbering, final identity and protection are verified, the containing directory is synced, the staging link is removed, and the containing directory is synced again.

The staging namespace is mode `0700` before the credential-bearing inode is created.
The staged inode is made and verified mode `0600` before plaintext is written.
Orchard retains a second descriptor bound to the same inode for logical containment until publication commits.
Pathname cleanup proceeds only after identity verification and never intentionally deletes a replaced or foreign pathname.

Successful publication means one intentional plaintext pathname at the operator-selected destination.
A failed command may have partial filesystem side effects.
After credential commit, unconfirmed publication returns nonzero even when descriptor-bound logical containment succeeds.
Unresolved descriptor-bound containment returns a distinct nonzero result.
Both outcomes state that plaintext may remain, expose only the API Token prefix, keep logs and audit records secret-free, and provide revocation and recovery guidance.

Logical containment means best-effort truncation and sync through the bound inode descriptor.
It does not guarantee physical-media sanitization, erase storage history, or guarantee cleanup when the filesystem refuses every applicable operation.
A close anomaly after publication commit is a warning and does not convert confirmed publication into failure.

Pending credential activation, durable publication permits, and API-key lifecycle redesign are deferred.

## Consequences

The final pathname never exposes an incompletely protected credential inode.
No-clobber installation preserves pre-existing and racing foreign pathnames.
Operators and automation can distinguish active credential authority, filesystem publication, and logical containment without parsing prose.
An operator may receive a nonzero result while the credential is active and while empty or unresolved filesystem metadata remains.
Recovery therefore begins by revoking the reported API Token prefix before retrying with a new output path.

## SPEC.md impact

§7.4.4 defines the protected file-backed publication protocol, bounded fault model, and exactly-once meaning.
§11.9 defines the `orchard.cluster_management.cluster_init.v2` outcome axes and post-commit recovery behavior.
