# Design: Enforce inference capture modes

## Context

The current Request row contains multiple content-bearing fields, and `request_events.payload` can carry additional model output.
Serializer-only enforcement would miss QueueManager and RequestServer write paths.
The Requests context is the narrowest shared persistence boundary for every current writer.

## Resolution and snapshot

The capture lattice is `none < metadata < full`.
The Tenant setting resolves at logical Request creation.
For the Responses API, `store=false` caps the effective mode at `metadata`.
The resulting mode is stored in `requests.payload_capture_mode` and remains authoritative for later terminal and event writes.
Later Tenant policy changes do not widen an existing Request.
A future retry may use only the narrower of its source Request snapshot and the then-current Tenant policy.

## Per-mode data model

`none` keeps request and response hashes, token usage, stable error codes, state, timestamps, and required operational metadata.
It stores no request shape, preview, canonical payload, response payload, raw tool argument, or raw runtime error text.

`metadata` additionally keeps a fixed allowlisted request shape and an optional non-equivalent preview.
The shape contains counts, types, lengths, approved identifiers, and hashes, but no caller metadata values, stop text, tool definitions, tool arguments, rendered prompt, or input content.
A metadata preview is stored only when source text exceeds 512 Unicode code points.
It contains complete source grapheme clusters totaling at most 511 Unicode code points plus one ellipsis, so the retained preview can never equal the complete source.

`full` may keep the approved canonical request and final response.
Its convenience preview remains bounded to 512 Unicode code points without splitting a grapheme cluster.
Streaming `full` requests assemble and persist the final response only at terminal completion, not as per-chunk durable writes.

## Persistence boundary

One pure `Orchard.Requests.CapturePolicy` transforms create attributes, terminal attributes, and request event payloads.
For non-`full` event and scheduler payloads, the policy validates both field names and values through field-specific numeric, boolean, UUID, timestamp, exact-match, and closed-enum rules.
The scheduler allowlist retains the opaque cache-affinity HMAC and only its closed typed feedback fields because later placement queries require that non-recoverable key.
Tool-call identifiers needed for step correlation are replaced by deterministic hashes, while tool names and raw target references are removed.
`Orchard.Requests` applies it after locking or resolving the authoritative Request snapshot and before every database write.
Serializers remain responsible for API response construction and do not decide retention.

Database constraints reject canonical requests, request payloads, or response payloads on a non-`full` row.
They also reject previews over 512 characters and any preview on a `none` row.
Request events require application enforcement because a row-level CHECK cannot reference the parent Request.

## Hashes and previews

`body_hash` remains the request integrity anchor.
Requests without an idempotency key receive a deterministic hash of the serialized canonical request.
`response_hash` is SHA-256 over the complete serialized terminal response before capture transformation.
Hashes do not authorize replay and are never treated as recoverable content.

## Replay and retry

Idempotent replay requires a retained response payload.
Completed `none` and `metadata` Requests therefore return the existing `idempotency_not_replayable` conflict instead of reconstructing or widening capture.
Future operator retry returns `retry_source_unavailable` when the source canonical request was not retained.
No retry path may consult current Tenant policy to widen a source Request snapshot.

## Existing-row treatment and purge

Existing `metadata` and `none` rows are treated as mislabeled.
The migration derives approved hashes and bounded metadata artifacts where possible, removes full request and response payloads, removes raw previews and error text that do not meet the target mode, retains only a syntactically valid cache-affinity HMAC with its closed typed feedback fields, and clears all other legacy scheduler decisions and Request-event payloads that cannot be proven safe through SQL-level typed validation.
After cleanup, named constraints are validated.

The regression verifier explicitly classifies `requests.canonical_request`, `requests.request_payload`, `requests.response_payload`, `requests.response_preview`, `requests.request_shape`, `requests.sampling_params`, `requests.response_format`, `requests.scheduler_decision`, `requests.error_message`, and `request_events.payload`.
It fails when a newly added text, JSON, or binary request column is not classified.

## Rejected alternatives

Relabeling old rows as `full` would preserve content captured under a false metadata label and would not satisfy the owner decision.
A short-lived replay side table would recreate the same prohibited retention obligation.
Database triggers for request events add cross-row write complexity and are deferred until application enforcement and drift tests prove insufficient.
