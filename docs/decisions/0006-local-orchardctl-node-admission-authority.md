# Local orchardctl node admission uses controller runtime authority

Accepted.

Node-admission CLI commands are local operator/admin commands for source-dev and packaged controller hosts.
They execute inside the controller runtime context and do not require the caller to present an Admin API bearer token.
They still call the same admission domain functions, leader-only write gate, shared Action Preview builder, presenters, and cluster-scoped audit paths used by Admin API admission execution.

This is separate from ADR 0004.
Admin API remains service-account-owned bearer-token auth for HTTP callers.
The local CLI path exists because first-admin credential provisioning and remote Admin API transport are separate slices, while packaged and source-dev operators need a local controller-host recovery and review tool.

The trade-off is a parallel trust boundary: local OS/package access to `orchardctl` is treated as operator context for these commands.
That boundary must not silently expand to remote or tenant-scoped execution.
If a future remote CLI transport delegates to Admin API, it must preserve the shared admission contract and use the ADR 0004 token boundary.

SPEC.md impact: `SPEC.md` §11.9 records the local node-admission CLI authority boundary.
