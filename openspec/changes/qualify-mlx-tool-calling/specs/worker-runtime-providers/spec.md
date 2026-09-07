## ADDED Requirements

### Requirement: Provider-Normalized Tool Calls

Under `SPEC.md` §7.5.2, a Worker Runtime SHALL publish function arguments derived from the provider's parsed function result, without model-native wrappers or framing markers.
A provider with only complete-call parsing SHALL validate a complete tool block before emitting its calls.
Each emitted call SHALL identify a requested function, contain a JSON argument object, and preserve a stable request-local ID and zero-based index.
Calls SHALL remain client-executed under the base v1 contract.

#### Scenario: Model emits a named JSON wrapper

- **WHEN** a model emits a wrapper containing a function name and an arguments object
- **THEN** the Worker Runtime emits the parsed name and serialized arguments object separately
- **AND** it does not emit the wrapper as function arguments

#### Scenario: Block fails validation

- **WHEN** parsing fails or a parsed call references an unrequested function or invalid arguments
- **THEN** the request fails without emitting calls from that block
- **AND** the failure does not echo generated tool content

#### Scenario: Generation ends inside an unvalidated call

- **WHEN** generation is cancelled, truncated, or omits required closing framing
- **THEN** the Worker Runtime does not publish the unvalidated call
- **AND** the request cannot report that call as successfully completed

## MODIFIED Requirements


### Requirement: Runtime Provider Conformance

Every supported runtime provider SHALL pass the same provider-neutral conformance scenarios for negotiation, health, load, unload, generation, streaming, cancellation, capacity, failure normalization, and version skew.
Hardware-specific acceptance SHALL supplement and MUST NOT replace provider-neutral conformance.
A model/runtime profile claimed to support client tool work SHALL additionally prove correctly parsed arguments and a real client-executed tool-result continuation under `SPEC.md` §§7.2.4 and 7.5.2.

#### Scenario: Provider is proposed for support

- **WHEN** a runtime provider is proposed for support under a runtime-provider profile
- **THEN** it passes provider-neutral conformance
- **AND** it passes the applicable real-hardware acceptance lane

#### Scenario: Client tool support is qualified

- **WHEN** a model/runtime profile is qualified for a named client version
- **THEN** that client receives a valid function call, executes a synthetic tool, returns its associated result, and receives the expected final answer
- **AND** qualification identifies the model revision, runtime/parser version, API path, and client version
