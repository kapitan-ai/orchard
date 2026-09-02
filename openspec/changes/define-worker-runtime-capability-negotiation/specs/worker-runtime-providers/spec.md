## MODIFIED Requirements

### Requirement: Versioned Runtime Capability Negotiation
A Worker Runtime provider SHALL report protocol version, provider identity and version, supported artifact formats, runtime features, acceleration implementations, device-resource bindings, memory semantics, concurrency, and cache capabilities before those facts authorize work.
It SHALL report them through one additive provider-neutral capability envelope on the `GetStatus` response at the Node Agent-to-Worker Runtime boundary, together with a non-secret service incarnation that identifies the current worker process lifetime.
Artifact format, runtime features, acceleration implementation, device binding, memory semantics, concurrency, and cache capabilities SHALL be reported as complete supported profiles; each profile is indivisible evidence, and independent repeated fields whose Cartesian product could authorize an unadvertised combination are invalid evidence.
Profile identities SHALL be canonical and unambiguous within one response; duplicate or conflicting identities SHALL fail closed for that response.
The Node Agent alone SHALL own subprocess custody, receipt time, freshness, invalidation, parse and validity classification, and local exact-profile evaluation; provider-supplied timestamps MUST NOT establish freshness.
Unknown, malformed, incompatible, absent, stale, or duplicate required capability evidence MUST NOT be treated as affirmative compatibility.
An omitted envelope is `absent`; a present but invalid envelope SHALL be classified as invalid and MUST NOT be silently treated as absent.
The local evaluator SHALL distinguish `absent`, `malformed`, `duplicate_or_conflicting`, `incompatible`, `stale`, `unknown`, and query-level `unsupported` from a successful proof with deterministic precedence.
Until a separately reviewed cutover, the evaluator MUST NOT change readiness, admission, dispatch, scheduling, retry, Runtime Endpoint projection, or public behavior.
This requirement changes the MLX-default assumptions in `SPEC.md` §§1.5, 4.6.1, 5.5, and 7.5.2a and makes the evidence sentences of `SPEC.md` §4.10 executable.

#### Scenario: New Node Agent contacts an older worker
- **WHEN** an older worker omits additive capability negotiation fields
- **THEN** the Node Agent decodes the response without crashing
- **AND** it does not claim capabilities the worker did not prove
- **AND** the local evidence classification is `absent`

#### Scenario: Envelope is present but structurally invalid
- **WHEN** a worker sends an envelope with a zero protocol major version, an empty provider identity, or a profile with an empty or non-canonical identifier
- **THEN** the Node Agent classifies the evidence as `malformed`
- **AND** the classification is not `absent`
- **AND** no profile from that response can prove a capability

#### Scenario: Two profiles share an identity
- **WHEN** a worker sends two profiles with the same profile identifier or the same canonical component tuple
- **THEN** the Node Agent classifies the whole response as `duplicate_or_conflicting`
- **AND** neither profile proves a capability

#### Scenario: Protocol major version does not match
- **WHEN** a worker reports a protocol major version the Node Agent does not support
- **THEN** the Node Agent classifies the evidence as `incompatible`
- **AND** provider identity alone does not rescue compatibility

#### Scenario: Evidence outlives its freshness window
- **WHEN** the Node Agent evaluates a query against a snapshot whose receipt time is older than the configured freshness window
- **THEN** the classification is `stale`
- **AND** a newer provider-supplied timestamp does not make it fresh

#### Scenario: Worker process is replaced
- **WHEN** the supervised worker exits, is restarted, or reports a different service incarnation than the retained snapshot
- **THEN** the Node Agent invalidates the retained evidence
- **AND** evaluation reports `absent` until a new envelope is received from the new incarnation

#### Scenario: Query matches only unrecognised vocabulary
- **WHEN** every profile that could satisfy a query uses a component value the Node Agent does not recognise
- **THEN** the evaluation result is `unknown`
- **AND** it is not reported as `supported` or `unsupported`

#### Scenario: Query combines advertised components that no single profile advertises
- **WHEN** a query requests an artifact format, acceleration implementation, and device binding that each appear in some profile but not together in one profile
- **THEN** the evaluation result is `unsupported`
- **AND** no Cartesian combination is inferred

#### Scenario: Query exactly matches one complete profile
- **WHEN** a query exactly matches one advertised profile of fresh valid compatible evidence
- **THEN** the evaluation result is a proof naming that profile identifier and the service incarnation

#### Scenario: Evaluator does not gate behaviour
- **WHEN** the envelope is present, absent, or classified as invalid
- **THEN** worker readiness, request admission, placement capacity, dispatch, retry, Runtime Endpoint status projection, and public API behaviour are unchanged

## ADDED Requirements

### Requirement: Optional Loaded Binding Defers To The Reasoning Contract
The capability envelope SHALL carry at most one optional local loaded binding naming the loaded model, its exact artifact identity, and the selected profile identifier.
The loaded binding SHALL reuse the canonical worker incarnation and artifact identity accepted for the negotiated reasoning contract under `SPEC.md` §7.5.3a when that contract is accepted before this change is implemented.
When that contract is not yet accepted, the loaded binding SHALL be omitted from this change rather than encoded with a parallel identity.
A present loaded binding that names a profile identifier not advertised in the same response SHALL classify the response as `duplicate_or_conflicting`.
This requirement refines `SPEC.md` §§4.10 and 7.5.3a.

#### Scenario: Loaded binding names an unadvertised profile
- **WHEN** the envelope's loaded binding references a profile identifier that is not among the response's profiles
- **THEN** the Node Agent classifies the response as `duplicate_or_conflicting`

#### Scenario: Reasoning contract identity not yet accepted
- **WHEN** this change is implemented before the §7.5.3a incarnation and artifact identity encoding is accepted
- **THEN** the envelope carries no loaded binding field
- **AND** the design records the deferred field for a later additive change

### Requirement: Capability Fixtures Prove Additive Decoding Only
Committed reciprocal fixtures SHALL include a current-revision `GetStatus` response with a populated envelope and a previous-revision response without one, encoded by each owning language binding and decoded by the other with semantic equality.
Passing those fixtures proves additive wire decoding across the two schema revisions only and MUST NOT be presented as a wider supported Node Agent and Worker Runtime product-version window than `SPEC.md` §13.1 grants.
This requirement refines `SPEC.md` §§7.5.2a and 13.1.

#### Scenario: Previous-revision fixture decodes
- **WHEN** the Node Agent binding decodes the committed previous-revision fixture
- **THEN** every legacy field is preserved
- **AND** the capability evidence classifies as `absent`

#### Scenario: Current-revision fixture round-trips
- **WHEN** the Python binding encodes the current-revision fixture and the Elixir binding decodes it
- **THEN** protocol version, provider identity, every profile, and the service incarnation are semantically equal
