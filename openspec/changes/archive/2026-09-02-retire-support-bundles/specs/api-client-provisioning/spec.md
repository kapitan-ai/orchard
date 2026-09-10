## MODIFIED Requirements

### Requirement: One-time Secret Output is never persisted

Orchard SHALL display or export plaintext API Token secrets only as One-time Secret Output after successful API Token creation.
Orchard MUST NOT persist plaintext token secrets in Postgres, audit logs, provisioning batches, Console assigns after dismissal, retired-feature artifacts retained on disk, local evidence logs, or raw OpenSpec artifacts.
The bulk provisioning CLI SHALL validate the operator-chosen output path before mutating state.
The bulk provisioning CLI SHALL support `--json` summaries without writing plaintext API Tokens to stdout.
One-time Secret Output CSV SHALL include `organization`, `api_client`, `external_ref`, `key_name`, `api_token_id`, `api_token_prefix`, `api_token`, and `expires_at`.
This changes `SPEC.md` §7.4.4, §10.2, §10.9, and §11.9 by defining secret handling for bulk token creation.

#### Scenario: Successful apply writes sensitive output once

- **WHEN** an operator applies a valid bulk provisioning batch with an output CSV path
- **THEN** Orchard persists only token prefixes and secret hashes
- **AND** Orchard writes plaintext API Token secrets to the chosen output file once
- **AND** Orchard excludes plaintext API Token secrets from audit payloads and provisioning batch records

#### Scenario: Output delivery failure preserves recovery evidence without plaintext

- **WHEN** an operator applies a valid bulk provisioning batch and the output file cannot be written after persistence succeeds
- **THEN** Orchard marks the Provisioning Batch `output_failed`
- **AND** Orchard emits a redacted output-failed audit event
- **AND** Orchard returns API Token prefixes for revocation or rotation
- **AND** Orchard does not persist plaintext API Token secrets
