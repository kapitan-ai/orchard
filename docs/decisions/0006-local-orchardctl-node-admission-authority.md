# Local orchardctl node admission uses controller runtime authority

Accepted.

Node-admission CLI commands are local operator/admin commands for source-dev and packaged controller hosts.
They execute inside the controller runtime context and do not require the caller to present an Admin API bearer token.
They still call the same admission domain functions, leader-only write gate, shared Action Preview builder, presenters, and cluster-scoped audit paths used by Admin API admission execution.
The same local controller-runtime authority boundary applies to node lifecycle commands: cordon, uncordon, drain, maintenance, resume, and decommission.
Lifecycle execution enforces the same leader-only write-path, confirmation, revalidation, and cluster-scoped audit semantics as admission execution.

This is separate from ADR 0004.
Admin API remains service-account-owned bearer-token auth for HTTP callers.
The local CLI path exists because first-admin credential provisioning and remote Admin API transport are separate slices, while packaged and source-dev operators need a local controller-host recovery and review tool.

The trade-off is a parallel trust boundary: local OS/package access to `orchardctl` is treated as operator context for these commands.
That boundary must not silently expand to remote or tenant-scoped execution.
If a future remote CLI transport delegates to Admin API, it must preserve the shared admission contract and use the ADR 0004 token boundary.

SPEC.md impact: `SPEC.md` §11.9 records the local node-admission and node-lifecycle CLI authority boundary.

## Platform portability scope

ADR 0024 refines this decision for the portable CLI target.
The current local Controller-runtime path remains the migration baseline, not the permanent authority model for normal operator operations.

Each migrated command family SHALL execute through Controller-owned authenticated, authorized, leader-aware, and audited domain operations shared by Console and CLI clients.
The local boundary MAY remain only for a narrow bootstrap or recovery operation that cannot yet use ordinary administrator credentials.
No command migration may weaken the action preview, confirmation, revalidation, audit, or secret-output contract established here.
