## ADDED Requirements

### Requirement: Negotiated reasoning encoding preserves legacy bindings

Before negotiated reasoning encoding is implemented, Orchard SHALL maintain reciprocal current-revision and N-1 fixtures for the Worker Runtime and both Runtime Endpoint bindings. The prior legacy fixtures remain byte-identical evidence that no reasoning field or event is sent to an older or non-advertising binding.

The fixture matrix SHALL cover absent, malformed, duplicate, conflicting, unknown, stale, and over-bound evidence; each independent tuple mismatch; loaded-instance replacement; proof loss, expiry, cancellation, and duplicate redemption; and `Failed` usage absent versus present zero. Synthetic exact-identity fixtures may exercise the dormant path, but the empty production registry and fixture success MUST NOT become a production-support claim or widen the supported version window.

#### Scenario: Legacy fixture decodes after additive schema work

- **WHEN** a current Node Agent decodes the retained N-1 worker fixture
- **THEN** it observes no reasoning capability
- **AND** it preserves the fixture's legacy status and event interpretation
