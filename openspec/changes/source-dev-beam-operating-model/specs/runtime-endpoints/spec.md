## ADDED Requirements

### Requirement: Source-dev BEAM Split-role Bootstrap
Orchard SHALL support Source-dev BEAM Runtime Endpoint mode first for the split-role `bin/dev-controller` and `bin/dev-node-agent` entrypoints.
When Source-dev BEAM mode is selected, both split-role processes SHALL start as named distributed BEAM nodes before Runtime Endpoint work is attempted.
All-in-one `bin/dev` SHALL remain on the current gRPC compatibility default in this change.
This refines the source-dev BEAM rollout rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: Split-role BEAM mode starts distributed nodes
- **WHEN** a contributor starts `bin/dev-controller` and `bin/dev-node-agent` with Source-dev BEAM Runtime Endpoint mode selected
- **THEN** each process starts with a configured BEAM node name
- **THEN** Runtime Endpoint operations use BEAM Distribution rather than the gRPC Compatibility Adapter

#### Scenario: All-in-one dev default is unchanged
- **WHEN** a contributor starts all-in-one `bin/dev` without selecting Source-dev BEAM mode
- **THEN** Orchard keeps using the current gRPC compatibility runtime transport on source-dev port `50071`

### Requirement: Source-dev BEAM Node Names
Source-dev BEAM node names SHALL use long-name format with IP-literal host parts for guarded BEAM Runtime Endpoint targets.
Controller nodes SHALL use role-identifying names such as `orchard_controller@<ip>`.
Node Agent nodes SHALL use role-identifying names such as `orchard_node_agent@<ip>`.
Source-dev BEAM target hostnames SHALL be rejected until hostname resolution and CIDR guardrail behavior are specified in a later change.
This refines BEAM Runtime Endpoint target rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: BEAM target uses IP-literal host
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains `orchard_node_agent@100.64.1.10` in Source-dev BEAM mode
- **THEN** Orchard accepts the target as a BEAM node-name address for guardrail validation

#### Scenario: BEAM target uses hostname host
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains `orchard_node_agent@worker.local` in Source-dev BEAM mode
- **THEN** Orchard rejects the target configuration before treating it as a schedulable Runtime Endpoint

### Requirement: Source-dev BEAM Cookie Material
Source-dev BEAM mode SHALL use explicit shared cookie material from `ORCHARD_BEAM_COOKIE_FILE`.
Same-host source dev SHALL be allowed to create a repo-local `tmp/dev/beam.cookie` file when no explicit cookie file exists.
Two-Mac source dev SHALL require identical cookie material to be provisioned on both Macs before BEAM Runtime Endpoint communication is used.
Cookie files MUST have mode `0600` or stricter, and Orchard MUST NOT print cookie contents in logs, templates, diagnostics, or startup output.
Ambient `$HOME/.erlang.cookie` MUST NOT be required for Source-dev BEAM mode.
This refines the first-party BEAM Distribution rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: Same-host cookie file is generated
- **WHEN** Source-dev BEAM mode starts on a single host with no `ORCHARD_BEAM_COOKIE_FILE` set and no existing repo-local cookie file
- **THEN** Orchard generates `tmp/dev/beam.cookie` with mode `0600`
- **THEN** startup output may show the cookie file path but not the cookie contents

#### Scenario: Cookie file has strict permissions
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_COOKIE_FILE` pointing to a readable file whose mode is `0600`
- **THEN** Orchard uses that file as the source-dev BEAM cookie material
- **THEN** startup output may show the cookie file path but not the cookie contents

#### Scenario: Cookie file permissions are weak
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_COOKIE_FILE` pointing to a file that is readable by group or world
- **THEN** Orchard rejects the BEAM startup configuration before Runtime Endpoint work is attempted

#### Scenario: Two-Mac cookie material differs
- **WHEN** the Controller and Node Agent are started in Source-dev BEAM mode with different cookie material
- **THEN** the BEAM connection fails visibly
- **THEN** Orchard does not retry the same Runtime Endpoint operation through gRPC automatically

### Requirement: Source-dev BEAM Distribution Networking
Source-dev BEAM mode SHALL define explicit distribution networking settings.
`ORCHARD_BEAM_EPMD_PORT` SHALL select the source-dev EPMD port and SHALL default to `4369` when unset.
`ORCHARD_BEAM_DIST_PORT_MIN` and `ORCHARD_BEAM_DIST_PORT_MAX` SHALL bound the BEAM distribution listener port range.
The two-Mac smoke procedure SHALL document reachability requirements for EPMD and the configured distribution listener range.
This refines Runtime Endpoint transport requirements in `SPEC.md` §1.2 and §7.5.

#### Scenario: EPMD and distribution ports are configured
- **WHEN** Source-dev BEAM mode starts with `ORCHARD_BEAM_EPMD_PORT`, `ORCHARD_BEAM_DIST_PORT_MIN`, and `ORCHARD_BEAM_DIST_PORT_MAX` set
- **THEN** Orchard starts the BEAM node with the selected EPMD port and bounded distribution listener range

#### Scenario: Distribution port range is invalid
- **WHEN** Source-dev BEAM mode starts with a distribution port minimum greater than the maximum
- **THEN** Orchard rejects the BEAM startup configuration before Runtime Endpoint work is attempted

### Requirement: Source-dev Runtime Endpoint Env Surface
Source-dev Runtime Endpoint transport selection SHALL use `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT`.
Source-dev BEAM Runtime Endpoint targets SHALL come from `ORCHARD_RUNTIME_ENDPOINT_TARGETS` and SHALL use BEAM node-name addresses.
Source-dev BEAM node bootstrap SHALL use `ORCHARD_BEAM_NODE_NAME`, `ORCHARD_BEAM_COOKIE_FILE`, `ORCHARD_BEAM_DIST_PORT_MIN`, `ORCHARD_BEAM_DIST_PORT_MAX`, and `ORCHARD_BEAM_EPMD_PORT`.
`ORCHARD_RUNTIME_CLIENT_TARGETS` SHALL remain scoped to gRPC Compatibility Adapter `host:port` targets and SHALL NOT be interpreted as BEAM Runtime Endpoint targets.
This refines the transport-independent Runtime Endpoint target rules in `SPEC.md` §1.2, §4.6.1, and §7.5.

#### Scenario: BEAM targets are read from Runtime Endpoint targets
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` and `ORCHARD_RUNTIME_ENDPOINT_TARGETS` contains BEAM node names
- **THEN** Orchard configures the BEAM Runtime Endpoint adapter with those targets
- **THEN** Orchard does not require `ORCHARD_RUNTIME_CLIENT_TARGETS` for BEAM Runtime Endpoint selection

#### Scenario: Legacy gRPC targets remain compatibility-only
- **WHEN** `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` and `ORCHARD_RUNTIME_CLIENT_TARGETS` is also set
- **THEN** Orchard treats `ORCHARD_RUNTIME_CLIENT_TARGETS` only as an explicit gRPC compatibility target list
- **THEN** Orchard does not merge those `host:port` values into the BEAM Runtime Endpoint target list

### Requirement: Source-dev BEAM No Automatic gRPC Fallback
When Source-dev BEAM Runtime Endpoint mode is selected, BEAM configuration, connection, guardrail, target identity, or Runtime Endpoint RPC failure SHALL fail visibly on the BEAM path.
The same request MUST NOT silently retry through the gRPC Compatibility Adapter.
gRPC compatibility SHALL remain available only when explicitly selected as the runtime transport.
This refines the source-dev transport rules in `SPEC.md` §1.2 and §7.5.

#### Scenario: BEAM connection fails
- **WHEN** Source-dev BEAM mode is selected and the configured Node Agent BEAM node is unreachable
- **THEN** Orchard reports the BEAM Runtime Endpoint failure visibly
- **THEN** Orchard does not execute the same request through gRPC automatically

#### Scenario: gRPC compatibility is explicitly selected
- **WHEN** a contributor selects the gRPC compatibility transport for source dev
- **THEN** Orchard uses the gRPC Compatibility Adapter target configuration
- **THEN** Source-dev BEAM target configuration is not required for that compatibility run

### Requirement: Source-dev BEAM Smoke Evidence Gate
Orchard SHALL require durable two-Mac Source-dev BEAM smoke evidence before BEAM Runtime Endpoint transport is promoted as the source-dev default.
The evidence SHALL be recorded in a sanitized durable repo document such as `docs/investigations/source-dev-beam-smoke-<date>.md`.
The evidence SHALL include date, commit, sanitized hosts, commands, controller and node-agent BEAM node names, remote Runtime Endpoint RPC evidence, Console Nodes reachability for local and remote Node Agents, `GET /v1/models` returning `200`, and `POST /v1/chat/completions` completing through Console Playground or an equivalent API request.
The evidence SHALL NOT include cookie material, credentials, raw local evidence logs, local tool session identifiers, or machine-specific filesystem paths.
Default promotion SHALL be proposed separately after the evidence gate passes.
This refines the accepted smoke language in `SPEC.md` §1.2 and §7.5.

#### Scenario: Smoke evidence is complete
- **WHEN** a two-Mac Source-dev BEAM smoke run records all required evidence in durable repo documentation
- **THEN** Orchard may consider a separate change that promotes BEAM Runtime Endpoint transport as the source-dev default

#### Scenario: Smoke evidence is absent
- **WHEN** no durable two-Mac Source-dev BEAM smoke evidence exists for the implementation commit
- **THEN** Orchard keeps the source-dev default on the gRPC compatibility path

### Requirement: Source-dev BEAM Scope Boundaries
Source-dev BEAM Operating Model behavior SHALL NOT make BEAM Distribution durable cluster truth.
Source-dev BEAM Operating Model behavior SHALL NOT allow external Runtime Endpoints to join the first-party BEAM mesh.
Source-dev BEAM Operating Model behavior SHALL NOT change the Node Agent to Worker Runtime boundary.
Packaged or release runtime configuration SHALL NOT inherit the repo-local source-dev cookie model.
This preserves the Runtime Endpoint and Worker Runtime boundaries in `SPEC.md` §1.2, §4.6.1, and §7.5.

#### Scenario: BEAM session is live
- **WHEN** a Source-dev BEAM Controller has a live connection to a Source-dev BEAM Node Agent
- **THEN** Postgres remains the durable source for inventory, lifecycle state, Runtime Endpoint Observations, scheduling history, request state, and operator-visible status

#### Scenario: Packaged runtime is configured
- **WHEN** a packaged or release Orchard runtime is configured
- **THEN** it does not use the repo-local `tmp/dev/beam.cookie` source-dev cookie model
