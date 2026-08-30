# observability-phase0-probe Specification

## Purpose
Define the versioned Phase 0 Responses acceptance probe, sanitized result contract, and pilot pin ownership.

## Requirements


### Requirement: Phase 0 probe configuration is exact and versioned

The Phase 0 probe SHALL accept only configuration schema version 1. The schema
SHALL freeze endpoint kind `responses`, path `/v1/responses`, streaming enabled,
positive connect and request timeouts, `probe_<lowercase UUID>` identifier,
cadence notes, terminal validation mode, and distinct environment variable
names for model and bearer credential. It MUST NOT accept literal model,
credential, prompt, tenant identifier, or DSN fields.

Non-loopback endpoints MUST use HTTPS. Plain HTTP MAY target only `localhost`,
`127.0.0.1`, or `::1`. URLs MUST NOT contain userinfo, a query, a fragment, an
empty authority, a malformed IPv6 authority, or an explicit port that is empty,
nonnumeric, control-bearing, whitespace-bearing, or outside `1..65535`. These
authority checks MUST apply to the raw URL before URI normalization. HTTPS
requests MUST disable redirects and verify both the peer and hostname with the
host system CA store. When that CA store cannot be loaded, the probe MUST refuse
before sending a request instead of raising. Resolved model and credential
values MUST satisfy bounded control-character-safe formats before request
construction.

#### Scenario: Valid remote configuration is loaded

- **WHEN** schema version 1 names distinct model and credential environment
  variables and selects an HTTPS `/v1/responses` endpoint
- **THEN** the probe resolves and validates the two values from the environment
- **AND** it sends the request with peer and hostname verification and redirects
  disabled

#### Scenario: Configuration or resolved values are unsafe

- **WHEN** configuration adds an unknown field, uses an invalid identifier,
names the same environment variable twice, selects a non-loopback HTTP URL,
includes malformed raw authority text or URL userinfo, or resolves a
control-bearing or oversized value
- **THEN** the probe refuses before sending a request

#### Scenario: Host transport prerequisites are unavailable

- **WHEN** an HTTPS endpoint is configured and the host system CA store cannot
  be loaded
- **THEN** the probe refuses before sending a request and still emits one
  sanitized result

### Requirement: Probe results are allowlisted and content-free

The probe SHALL serialize only `schema_version`, `probe_id`, `started_at`,
`finished_at`, `outcome`, `classification`, `public_request_id`,
`terminal_count`, `terminal_state`, `http_status`, and `latency_ms`.
`probe_id` MUST match `probe_<lowercase UUID>` except that it MAY be null for
`invalid_config`; it SHALL be null only when no configuration validated, and a
refusal after configuration validated SHALL retain the pinned identifier.
`public_request_id` MUST be null or match `resp_<lowercase UUID>`. All other
string values MUST be closed enums or UTC timestamps. Timestamp fields MUST be
validated without raising on non-string values. The result MUST NOT contain
prompts, response content, credentials, tenant identifiers, DSNs, stack traces,
exceptions, or unknown fields.

#### Scenario: Safe result is serialized

- **WHEN** every field conforms to result schema version 1 and its identifier
grammar
- **THEN** exactly the allowlisted scalar fields are emitted as JSON

#### Scenario: HTTP implementation returns an out-of-contract status

- **WHEN** the HTTP implementation returns a status outside `100..599`
- **THEN** the probe emits a failed `http_error` result with `http_status` null
- **AND** serialization does not raise

#### Scenario: Content-bearing or wrongly typed field is presented

- **WHEN** an allowlisted identifier contains arbitrary content instead of its
  canonical grammar, or a timestamp field holds a non-string value
- **THEN** serialization is refused

#### Scenario: Refusal occurs after configuration validated

- **WHEN** a required environment variable, resolved value, transport
  prerequisite, or database prerequisite refuses after schema validation
  succeeded
- **THEN** the `invalid_config` result retains the configured `probe_id`

### Requirement: Buffered typed terminal determines HTTP-only outcome

The Phase 0 probe SHALL examine the complete buffered response using Orchard's
narrow one-`event`/one-`data` SSE framing only when the response contains exactly
one `Content-Type` field whose media type is `text/event-stream`; parameters MAY
follow that media type. Missing, wrong, or ambiguous content type SHALL fail as
`invalid_stream`. A block is a terminal candidate when either the SSE event or
decoded JSON type names `response.completed` or `response.failed`. Every
candidate MUST have exactly one event and one data field, matching event and JSON
types, a response object, a canonical public ID, and a legal status. A colonless
`event` or `data` line counts as an additional field with an empty value and
therefore invalidates a terminal candidate. `response.completed` accepts only
`completed`; `response.failed` accepts only `failed` or `incomplete`.

The probe SHALL pass only for exactly one valid `response.completed` candidate
and no invalid terminal candidate. Missing, duplicate, malformed, mismatched,
repeated-field, or invalid-UTF-8 terminals SHALL fail as `invalid_stream` and
SHALL NOT retain response content.

#### Scenario: Stream completes once

- **WHEN** a single `text/event-stream` content type is present and unrelated
  producer events precede exactly one legal `response.completed` terminal
- **THEN** outcome is `pass` and classification is `completed`
- **AND** the canonical public request ID and completed status are retained

#### Scenario: Terminal intent is malformed on either plane

- **WHEN** either the SSE event or decoded JSON type identifies a terminal but
  its framing, type, response object, ID, or status is invalid
- **THEN** outcome is `fail` and classification is `invalid_stream`
- **AND** the candidate is not discarded even if another valid terminal exists

#### Scenario: Response media type is not unambiguous SSE

- **WHEN** a 200 response omits `Content-Type`, uses another media type, or
  presents multiple or comma-joined media types
- **THEN** outcome is `fail` and classification is `invalid_stream`
- **AND** the body is not classified as terminal evidence

### Requirement: Controller-local mode reconciles HTTP and durable terminals

Controller-local reconciliation SHALL apply only to an observed SSE terminal,
that is classification `completed` or `response_failed`. A `transport_error`,
`http_error`, or `invalid_stream` observation SHALL retain its classification so
the reported failure names the plane that actually failed.

For an observed terminal, Controller-local mode SHALL require a canonical public
ID, look up its request, and list ordered events. It SHALL require exactly one
durable terminal `state_transition` matching `request.state`, then require
agreement with the HTTP terminal: completed maps only to durable completed;
failed maps to durable failed, cancelled, timed out, or interrupted; incomplete
maps only to durable cancelled, timed out, or interrupted. HTTP-only mode SHALL
NOT require database access.

#### Scenario: Durable and HTTP terminals agree

- **WHEN** the durable row and sole terminal event agree and satisfy the mapping
  for the observed HTTP terminal
- **THEN** the HTTP classification is preserved
- **AND** durable count and state are reported

#### Scenario: Durable evidence is missing or contradictory

- **WHEN** a terminal was observed and the public ID is missing, lookup or event
  listing fails, the durable invariant fails, or HTTP and durable outcomes
  disagree
- **THEN** outcome is `fail` and classification is
  `terminal_validation_failed`
- **AND** an active durable row state is reported as null
- **AND** ordinary database exception or exit detail is not serialized

#### Scenario: No terminal was observed to reconcile

- **WHEN** Controller-local mode classifies a transport, HTTP, or stream failure
  instead of a terminal event
- **THEN** that classification is reported unchanged with outcome `fail`
- **AND** no durable lookup is attempted

### Requirement: Launcher preserves caller path and owned exit semantics

The launcher SHALL resolve relative configuration paths against the caller's
working directory before entering the repository root. It SHALL reserve stdout
for the result JSON after compilation and document exit `0` for pass, `1` for a
validated failed observation, `2` for pre-request configuration or environment
refusal, and `64` for usage. Toolchain or VM failures MAY return other runtime
exit codes.

#### Scenario: Caller supplies a relative invalid configuration

- **WHEN** the launcher is invoked from another directory with a relative path
  to invalid JSON
- **THEN** it reads that caller-relative file, emits an `invalid_config` result,
  and exits `2`

### Requirement: Pilot consumer pins exact producer and configuration

Issue #115 SHALL own the versioned probe producer artifact and pin example.
Issue #118 SHALL own its CP1 configuration, actual pin, invocation cadence,
and retained results. The consumer pin SHALL record a 40-character producer
Git commit SHA and SHA-256 of the exact non-secret configuration bytes.

#### Scenario: Consumer updates or rolls back the probe

- **WHEN** issue #118 adopts or restores a producer revision and configuration
- **THEN** it records and verifies the corresponding commit and config digest
- **AND** it collects a fresh result
