## ADDED Requirements

### Requirement: Capture Mode Resolution Is Durable And Never Widens

Orchard SHALL persist a validated Tenant request-body capture mode of `none`, `metadata`, or `full`, defaulting to `metadata`.
Orchard SHALL resolve and snapshot the effective mode on each logical Request before its first persistence write.
For the Responses API, `store=false` SHALL cap `full` at `metadata` and SHALL NOT widen `none` or `metadata`.
All attempts and terminal writes for a logical Request MUST use its snapshot.
This requirement refines `SPEC.md` sections 7.4.2 and 10.10.

#### Scenario: Store false narrows a full Tenant

- **WHEN** a Tenant policy is `full` and a Responses request sets `store=false`
- **THEN** Orchard snapshots `metadata`
- **AND** the HTTP response remains complete
- **AND** durable persistence follows `metadata`

#### Scenario: Later Tenant change does not widen an active Request

- **WHEN** a Request snapshots `none`
- **AND** the Tenant policy later changes to `full`
- **THEN** every later event and terminal write remains governed by `none`

### Requirement: Capture Modes Bound Every Persisted Content Field

Orchard SHALL enforce capture policy at the Requests persistence boundary for Request rows and request event payloads.
`none` SHALL retain hashes, usage, stable error codes, state, timestamps, and required operational metadata but no prompt, response, preview, raw tool argument, or raw runtime error text.
`metadata` SHALL additionally retain only an allowlisted bounded shape and an optional non-equivalent preview.
A metadata preview SHALL exist only when its source exceeds 512 Unicode code points and SHALL contain complete source grapheme clusters totaling at most 511 Unicode code points plus one ellipsis.
`full` MAY retain approved canonical request and response payloads, and its convenience preview SHALL remain at most 512 Unicode code points without splitting a grapheme cluster.
This requirement refines `SPEC.md` section 10.10.

#### Scenario: Metadata row cannot contain full content

- **WHEN** a caller submits short or long prompt, tool, and response content under `metadata`
- **THEN** no persisted Request or request event field contains the complete prompt, complete response, tool arguments, caller metadata values, stop text, or raw runtime error
- **AND** any retained preview is not equal to its complete source

#### Scenario: Full streaming persists one terminal response

- **WHEN** a `full` streaming Request completes
- **THEN** Orchard persists the approved assembled final response
- **AND** Orchard does not persist individual stream chunks as separate content copies

### Requirement: Replay And Retry Fail Safely Without Source Content

Idempotent replay SHALL require a retained response payload.
A matching completed Request without one SHALL return `idempotency_not_replayable`.
A future operator retry SHALL return `retry_source_unavailable` when its source canonical request is absent.
Any future retry Request MUST snapshot a mode no wider than both its source Request and the current Tenant policy.
This requirement refines `SPEC.md` section 7.3.4 and section 10.10.

#### Scenario: Metadata request is not replayable

- **WHEN** a completed `metadata` Request is repeated with the same idempotency key and body hash
- **THEN** Orchard returns `idempotency_not_replayable`
- **AND** Orchard does not reconstruct or recover the omitted response

### Requirement: Existing Mislabeled Rows Are Purged And Verifiable

Orchard SHALL purge existing `none` and `metadata` rows that contain content forbidden by their label.
The purge SHALL cover every classified content-bearing Request column and `request_events.payload`.
Named database constraints SHALL reject full request or response payloads on non-`full` rows, previews on `none` rows, and previews over 512 characters.
A schema-drift regression SHALL fail when a newly added text, JSON, or binary Request column is not classified for capture and purge.
This requirement refines `SPEC.md` section 10.10.

#### Scenario: Post-migration verification names every content column

- **WHEN** the capture migration completes
- **THEN** verification checks `canonical_request`, `request_payload`, `response_payload`, `response_preview`, `request_shape`, `sampling_params`, `response_format`, `scheduler_decision`, `error_message`, and `request_events.payload`
- **AND** no `none` or `metadata` row retains forbidden content
