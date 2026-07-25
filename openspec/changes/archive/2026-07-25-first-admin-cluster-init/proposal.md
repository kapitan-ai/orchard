## Why

A fresh Orchard deployment has no supported way to mint the first cluster-admin credential (issue #75).
ADR 0004 defined the credential shape and deferred provisioning; SPEC.md §11.9 requires `orchardctl cluster init` and §11.7 places it in the offline install flow, but the CLI stub is deferred and no minting path exists.
Until this lands, the Admin API cannot be presented as operator-usable on a fresh install.

## What Changes

- Define `orchardctl cluster init` as the local, one-shot, audited first-admin credential mint per ADR 0011: service-account-owned API Client with a cluster-scoped `admin` RoleBinding and a hash-only API Token, one-time secret output through the §7.4.4 pattern, `cluster_already_initialized` guard, `--force-new-admin` additive break-glass with confirmation and audit, leader-only write gate.
- Keep first-admin provisioning off the network: no Admin API endpoint, no installer seeding, no repurposing of node-join Bootstrap Tokens.
- Keep the slice credential-only: TLS provisioning and any first-admin bootstrap UI remain separate work.
- Implement the governance bootstrap module, the real CLI command, and happy-path plus failure-path tests.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `api-client-provisioning`: gains the first cluster-admin credential provisioning requirement (`orchardctl cluster init` contract).
