## ADDED Requirements

### Requirement: Phase 0 probe configuration is exact and versioned

The Phase 0 probe SHALL accept only configuration schema version 1. The schema
SHALL freeze endpoint kind `responses`, path `/v1/responses`, streaming enabled,
positive connect and request timeouts, a probe identifier, cadence notes,
terminal validation mode, and environment variable names for model and bearer
credential. It MUST NOT accept the model value, credential value, prompt,
tenant identifier, or DSN as configuration fields.

#### Scenario: Valid remote configuration is loaded

- **WHEN** schema version 1 names model and credential environment variables,
  selects `responses`, uses `/v1/responses`, enables streaming, and selects
  `http_only`
- **THEN** the probe resolves the two values from the environment
- **AND** it sends a streaming Responses request within the configured timeouts

#### Scenario: Configuration adds or changes a contract field

- **WHEN** a configuration has an unknown field, unsupported schema version,
  non-Responses endpoint, non-streaming mode, invalid timeout, or literal model
  or credential value
- **THEN** the probe refuses the configuration before sending a request

### Requirement: Probe results are allowlisted and content-free

The probe SHALL serialize only `schema_version`, `probe_id`, `started_at`,
`finished_at`, `outcome`, `classification`, `public_request_id`,
`terminal_count`, `terminal_state`, `http_status`, and `latency_ms`. The result
MUST NOT contain prompts, response content, credentials, tenant identifiers,
DSNs, stack traces, exceptions, or any unknown field.

#### Scenario: Safe result is serialized

- **WHEN** every field conforms to result schema version 1
- **THEN** exactly the allowlisted scalar fields are emitted as JSON

#### Scenario: Content-bearing or secret-bearing field is presented

- **WHEN** a result includes a prompt, response, credential, secret, token,
  tenant identifier, DSN, stack trace, exception, or another unknown field
- **THEN** serialization is refused

### Requirement: Streaming Responses terminal determines HTTP-only outcome

The probe SHALL classify an HTTP 200 stream with exactly one typed
`response.completed` terminal as `completed` and passing. A typed
`response.failed`, non-200 response, transport failure, missing terminal,
duplicate terminal, or malformed terminal SHALL fail with a stable
classification and SHALL NOT retain the response body.

#### Scenario: Stream completes once

- **WHEN** the stream contains exactly one valid `response.completed` event
- **THEN** outcome is `pass`
- **AND** classification is `completed`
- **AND** the public request ID and terminal state are taken from that event

#### Scenario: Stream terminal is invalid or ambiguous

- **WHEN** the stream has no valid terminal, more than one valid terminal, or a
  malformed terminal payload
- **THEN** outcome is `fail`
- **AND** classification is `invalid_stream`

### Requirement: Controller-local mode validates durable terminal state

Controller-local mode SHALL look up the request by the public ID observed in
the typed stream and list its ordered request events. It SHALL require exactly
one lifecycle `state_transition` with a terminal state matching
`request.state`. HTTP-only mode SHALL NOT require database access.

#### Scenario: Durable terminal matches

- **WHEN** exactly one terminal `state_transition` exists and its state matches
  the persisted request state
- **THEN** the HTTP classification is preserved
- **AND** `terminal_count` is `1`
- **AND** `terminal_state` is the persisted terminal state

#### Scenario: Durable terminal is missing, duplicated, or mismatched

- **WHEN** lookup fails or the durable terminal invariant does not hold
- **THEN** outcome is `fail`
- **AND** classification is `terminal_validation_failed`

### Requirement: Pilot consumer pins exact producer and configuration

Issue #115 SHALL own the versioned probe producer artifact and pin example.
Issue #118 SHALL own its CP1 configuration, actual pin, invocation cadence,
and retained results. The consumer pin SHALL record a 40-character producer
Git commit SHA and SHA-256 of the exact non-secret configuration bytes.

#### Scenario: Consumer updates the probe

- **WHEN** issue #118 adopts a different producer revision or configuration
- **THEN** it records the new commit SHA and config digest after review
- **AND** it collects a fresh probe result before accepting the pin

#### Scenario: Consumer rolls back the probe

- **WHEN** issue #118 rejects an update
- **THEN** it restores the prior recorded commit and byte-identical config
- **AND** it verifies the digest and collects a fresh result
