## Design Notes

### Trust boundary

First-admin minting runs under the ADR 0006 local controller-runtime authority boundary: local OS access to `orchardctl` on the controller host is operator context, no bearer token exists yet, and the leader-only write gate plus cluster-scoped audit apply exactly as they do for node-admission commands.
A network bootstrap endpoint was rejected (unauthenticated mint surface, fresh-install race window, reset procedure that needs local disk authority anyway); installer seeding was rejected (external Postgres is configured after install, §11.4 forbids installer-generated trust material, unattended MDM installs would scatter secrets); environment seeding was rejected (long-lived plaintext in launchd env files).
Prior art: kubeadm local `admin.conf`, k3s server-local token, Nomad one-shot `acl bootstrap`, Vault init-then-revoke-root guidance.

### One-shot guard race

Two concurrent `cluster init` runs on a fresh database must not both succeed.
The guard query (no enabled API Client with a cluster-scoped `admin` RoleBinding) runs inside the minting transaction; race safety comes from a uniqueness guarantee rather than the read alone — either a partial unique index on cluster-scoped admin role bindings or an equivalent serializable/advisory-locked check.
The recovery path (`--force-new-admin`) skips the guard by design and is additive only.

### Secret handling

The token secret exists in memory once: generated, written to the preflighted `--output` destination, and returned to the operator.
Postgres stores hash and prefix only (ADR 0002 / SPEC §10.2 discipline).
Output preflight runs before any database mutation so a failed write cannot strand a minted-but-unsaved credential; if the output write fails after mint, follow the `mark_output_failed` precedent from `ApiClientProvisioning`.
No default expiry: rotation is guidance, not enforcement, per ADR 0011.

### Active/Standby

The leader-only write gate makes the command safe under Active/Standby from day one: a standby controller refuses with the existing standby semantics, and an unproven leader refuses with `controller_leadership_unproven` per the PR #69 write-gate contract.
