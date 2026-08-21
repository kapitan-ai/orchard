## MODIFIED Requirements

### Requirement: EnsureModelLoadedRequest.deadline_unix_ms carries the effective load-operation deadline
`EnsureModelLoadedRequest.deadline_unix_ms` SHALL be the effective deadline for the
specific load operation, computed as the minimum of the absolute Request deadline and
the dispatcher's model-load stage cap (`now + min(max_cold_start_ms, remaining_request_time)`).
The orchestrator SHALL NOT stamp the absolute Request deadline into this field.
The dispatcher SHALL rewrite the field immediately before issuing the Runtime Endpoint call.

This implements `SPEC.md` §7.5.3, §cold-tier, and §dispatch stage-deadline wording.

#### Scenario: Cold load exceeds the stage cap but fits inside the Request deadline
- **GIVEN** a Request with `timeout_at` 120 s from now
- **AND** a routing policy with `max_cold_start_ms` of 15 s
- **AND** a model that takes longer than 15 s to load
- **WHEN** the dispatcher sends `EnsureModelLoaded`
- **THEN** `deadline_unix_ms` is approximately 15 s from the dispatch start
- **AND** the controller reports a load-stage timeout without waiting for the Request deadline

#### Scenario: Request deadline is shorter than the stage cap
- **GIVEN** a Request with less than `max_cold_start_ms` remaining
- **WHEN** the dispatcher computes the load deadline
- **THEN** the effective deadline equals the Request deadline
- **AND** the timeout classification is `request_timeout` rather than `load_timeout`

## ADDED Requirements

### Requirement: Model-load stage timeout is classified as load_timeout
A model-load operation that cannot complete before the effective load deadline SHALL
be classified as a timeout failure with stable code `load_timeout`.
Non-streaming responses SHALL return HTTP 504.
Streaming responses that have already committed headers SHALL emit one SSE error event
with code `load_timeout` and SHALL NOT emit a `[DONE]` marker.
Persisted request state SHALL be `failed` with `http_status=504` and `error_code="load_timeout"`.

This implements `SPEC.md` §failure normalization and §request-deadline stage-deadline wording.

#### Scenario: gRPC deadline exceeded on EnsureModelLoaded
- **GIVEN** the Runtime Endpoint returns a gRPC deadline exceeded status
- **WHEN** integer status 4 or atom `:deadline_exceeded` is received
- **THEN** the dispatcher normalizes it to `timeout` category and code `load_timeout`
- **AND** the failure is NOT mapped to `internal_error`

#### Scenario: BEAM runtime endpoint timeout on EnsureModelLoaded
- **GIVEN** the BEAM Runtime Endpoint `:rpc.call` times out
- **WHEN** the transport returns `:beam_node_timeout`
- **THEN** it normalizes to `timeout` category and code `load_timeout`

#### Scenario: Local BEAM same-node timeout is enforced
- **GIVEN** the controller and target share the same BEAM node
- **WHEN** `BeamClient` is called with `timeout:` for `ensure_model_loaded`
- **THEN** the call is bounded by that timeout
- **AND** expiry returns `:beam_node_timeout`

### Requirement: Node Agent does not mark a worker loaded after all waiters expired
The Node Agent SHALL NOT mark a worker placement as `PLACEMENT_STATE_LOADED` when a load
task completes after every valid waiter for that load has expired.
Cached model artifacts MAY remain; runtime residency requires an active owner.
An explicit preload remains a valid residency owner and is exempt from this cleanup.

This implements the `SPEC.md` invariant that a load exceeding its remaining deadline
cannot proceed to execution.

#### Scenario: Controller abandons load before Node Agent finishes
- **GIVEN** the controller's `EnsureModelLoaded` call times out
- **AND** the Node Agent load task completes shortly after
- **THEN** the Node Agent does not mark the worker loaded for that request
- **AND** a subsequent request still sees a cold load unless another valid load owns it

#### Scenario: Explicit preload completes without inference waiters
- **GIVEN** an explicit preload owns the load operation
- **WHEN** the load completes without an inference waiter
- **THEN** the Node Agent may retain the loaded worker placement
