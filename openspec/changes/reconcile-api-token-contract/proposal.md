## Why

Orchard's implemented API Token codec conflicts with the normative format, entropy, and hash-input requirements in `SPEC.md` §10.2.
The mismatch affects every API Token creation and authentication path, while the completed first-admin change also lacks independent PostgreSQL-session race evidence and explicit log-capture evidence.

## What Changes

- Make new API Token issuance conform to the canonical `orchard_sk` contract and `orchard_kp` persisted prefix mapping.
- Preserve existing `orch_<public>.<secret>` credentials through indefinite dual-format authentication compatibility without a database migration.
- Clarify the exact canonical component encoding and secret hash input in `SPEC.md`.
- Add independent PostgreSQL-session coverage for the first-admin one-shot guard.
- Add captured-log coverage for successful and failed first-admin One-time Secret Output delivery.
- Keep `first-admin-cluster-init` active and do not archive it in this change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `api-client-provisioning`: defines canonical API Token issuance, legacy credential authentication compatibility, and the missing first-admin regression evidence.

## Impact

This changes the platform-wide API Token codec used by tenant-direct, API Client, bulk-provisioned, and first-admin credentials.
Authentication remains compatible with already-issued credentials, and the existing `api_keys` persistence schema remains unchanged.
Console, packaging, node-enrollment credentials, and unrelated credential families are excluded.
