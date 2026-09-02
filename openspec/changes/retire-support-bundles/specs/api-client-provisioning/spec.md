## MODIFIED Requirements

### Requirement: One-time Secret Output is explicit and ephemeral

Bulk provisioning Apply SHALL emit plaintext API Token secrets exactly once to an operator-chosen file or secret-manager adapter.
Orchard MUST NOT persist plaintext token secrets in Postgres, audit logs, provisioning batches, Console assigns after dismissal, local evidence logs, raw OpenSpec artifacts, or any retired-feature artifact retained on disk.
The bulk provisioning CLI SHALL validate the operator-chosen output path before mutating state.
The bulk provisioning CLI SHALL support `--json` summaries without writing plaintext API Tokens to stdout.
Local file output SHALL use owner-only permissions and create a new file without overwriting an existing path.
Plaintext output files SHALL remain operator-custodied and SHALL NOT be auto-deleted by Orchard.

#### Scenario: Apply writes secrets once

- **WHEN** an operator applies a valid bulk provisioning batch with an output CSV path
- **THEN** Orchard creates the output file with owner-only permissions
- **AND** Orchard writes each new plaintext API Token exactly once
- **AND** Orchard excludes plaintext API Token secrets from audit payloads and provisioning batch records

#### Scenario: Post-commit output delivery fails

- **WHEN** an operator applies a valid bulk provisioning batch and the output file cannot be written after persistence succeeds
- **THEN** Orchard marks the Provisioning Batch `output_failed`
- **AND** Orchard emits a redacted audit event
- **AND** Orchard returns the affected API Token prefixes for revocation or rotation
