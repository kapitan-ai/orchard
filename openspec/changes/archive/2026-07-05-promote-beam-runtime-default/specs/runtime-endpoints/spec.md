## ADDED Requirements

### Requirement: Source-dev Split-role BEAM Transport Default
Source-dev split-role launches SHALL default to the BEAM Runtime Endpoint transport.
`bin/dev-controller` and `bin/dev-node-agent` SHALL behave as if `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` when the variable is unset.
The gRPC compatibility transport SHALL remain available only through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
This changes the source-dev default transport language currently described alongside `SPEC.md` section 7.5 internal communications and the split-role guidance in `docs/local-dev.md`.

#### Scenario: Default split-role launch uses BEAM
- **WHEN** `bin/dev-controller` or `bin/dev-node-agent` starts without `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` set
- **THEN** the process configures the BEAM Runtime Endpoint transport and BEAM distribution settings

#### Scenario: Explicit gRPC opt-out preserved
- **WHEN** `bin/dev-controller` or `bin/dev-node-agent` starts with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc`
- **THEN** the process configures the gRPC compatibility transport exactly as before this change

### Requirement: BEAM Mode Quiesces the Legacy gRPC Client Surface
When the BEAM Runtime Endpoint transport is selected, the controller SHALL NOT configure a default legacy gRPC runtime client target.
The implicit `127.0.0.1:50071` runtime client target SHALL be absent in BEAM mode unless `ORCHARD_RUNTIME_CLIENT_TARGETS` is explicitly set for deliberate gRPC comparison.
Explicitly set `ORCHARD_RUNTIME_CLIENT_TARGETS` values SHALL continue to configure only the gRPC compatibility surface.

#### Scenario: BEAM mode without explicit gRPC targets
- **WHEN** the controller starts in BEAM mode without `ORCHARD_RUNTIME_CLIENT_TARGETS` set
- **THEN** no legacy gRPC runtime client target is configured or logged as active

#### Scenario: Deliberate comparison targets remain possible
- **WHEN** the controller starts in BEAM mode with `ORCHARD_RUNTIME_CLIENT_TARGETS` explicitly set
- **THEN** the explicit gRPC targets are configured for comparison while BEAM remains the active Runtime Endpoint transport

### Requirement: All-in-one Source Dev Remains Single-host gRPC Loopback
All-in-one `bin/dev` SHALL keep its single-host gRPC loopback default and SHALL reject explicit BEAM mode with a clear error.
Split-role scripts SHALL remain the only supported source-dev BEAM entry points.

#### Scenario: All-in-one rejects explicit BEAM mode
- **WHEN** `bin/dev` starts with `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`
- **THEN** startup fails with a clear error directing the operator to the split-role scripts
