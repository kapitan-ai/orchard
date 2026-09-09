# ADR: Beam-first Runtime Endpoints

## Status

Accepted.
Source-dev split-role default promoted on 2026-07-05.
Production identity and authorization are refined by [ADR 0012](0012-scoped-beam-peer-grants.md).

## Context

Before this decision, `SPEC.md` defined cross-node control traffic as gRPC over mTLS and forbade distributed Erlang across machines.
That direction was chosen while Orchard's cluster boundary was still being worked out.
The current architecture uses Elixir for both the Controller and first-party Node Agent, while Python/MLX remains a local Worker Runtime detail behind the Node Agent.
The latest `gnhf/objective-fully-impl-369718` work strengthens concurrent inference behavior with live placement capacity, conservative scheduler eligibility, `cluster_busy` requeue semantics, and queue fairness.
Those semantics should be treated as target architecture inputs even though their current representation is gRPC/protobuf-shaped.

The key ambiguity is whether the Node Agent is a protocol-isolated runtime endpoint that happens to be implemented in Elixir, or a first-party Orchard BEAM participant that owns node-local execution.

## Decision

Model Orchard scheduling around transport-independent Runtime Endpoints.
The v1 Runtime Endpoint is the first-party Node Agent.
For first-party Runtime Endpoints, keep BEAM Distribution as the preferred live communication and monitoring layer between Elixir services when guardrails and rollout gates allow it.
Limit BEAM Distribution to first-party Orchard Runtime Endpoints.
External or provider-backed Runtime Endpoints must integrate through explicit Runtime Endpoint adapters and provider-appropriate protocols.

Keep Postgres as the durable persistence and coordination store.
BEAM Distribution must not become durable cluster truth.
Use BEAM Distribution for guarded live first-party communication, monitoring, and fast session failure signals.
Persist Runtime Endpoint Observations in Postgres for inventory, lifecycle, availability, scheduling, and operator-visible history.
A connected BEAM node is not automatically schedulable.
Production BEAM Distribution must be explicitly configured, identity-bound, network-restricted, and limited to admitted first-party Orchard services.
For enrolled production services, identity-bound means exact certificate validation plus an exact Controller-to-Node BEAM Peer Grant under ADR 0012, not a shared cookie or certificate-only OTP authorization.
External Runtime Endpoints must not join the BEAM mesh.

Keep the Runtime Endpoint Interface independent of a transport protocol.
The implementation defines an Elixir behaviour with the current gRPC Compatibility Adapter and a default-off first-party BEAM adapter behind the same Runtime Endpoint Interface.
Future Runtime Endpoint adapters may target external compute, cloud VMs, high-performance compute nodes, appliance-style accelerators, or paid provider integrations.
Existing `proto/cluster/v1` work should be demoted from the default first-party Controller-to-Node Agent path to a possible future adapter protocol.
Placement Capacity is a first-class Runtime Endpoint observation and must be exposed by the interface independently of transport.
Unknown, malformed, duplicate, or nonmatching Placement Capacity must not prove eligibility for an active loaded placement.

The BEAM Runtime Endpoint adapter is the primary source-dev Controller-to-Node Agent path for split-role `bin/dev-controller` and `bin/dev-node-agent` launches after accepted two-Mac smoke evidence and explicit promotion.
The accepted 2026-06-27 two-Mac smoke evidence is summarized here as the durable gate record.
That run tested base commit `995879a13710` with a controller plus local node-agent on one Mac and a remote node-agent on a second Mac, using three named BEAM nodes with sanitized RFC 5737 address literals, EPMD port `43690`, owner-only shared cookie files verified by digest, and the stub worker backend.
Both Runtime Endpoint targets were reachable through `BeamClient.connect/1` and `BeamClient.status/2` with `availability: :available`; Console Nodes reported two configured and two reachable targets with healthy runtime cards; `GET /v1/models` returned `200`; and `POST /v1/chat/completions` completed with dispatch outcome `ok` using `mlx-community/Llama-3.2-1B-Instruct-4bit`.
The 2026-07-05 refresh on `main` 3454423 revalidated BEAM transport, observation, admission, lifecycle actions, and multi-node scheduler explanations against a real remote node-agent.
The 2026-07-05 promotion makes split-role source dev behave as if `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` when the variable is unset.
Current split-role source dev continues to expose the gRPC Compatibility Adapter on port `50071` only through explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
The Source-dev BEAM Operating Model uses long BEAM node names with IPv4-literal hosts, explicit shared cookie material, bounded distribution networking, and BEAM-specific Runtime Endpoint target variables rather than legacy gRPC runtime client variables.
All-in-one `bin/dev` remains the gRPC default and rejects explicit BEAM mode.
Same-host source dev may generate a repo-local `tmp/dev/beam.cookie` file, while two-Mac source dev must provision the same cookie material on both Macs.
Packaged or release runtime configuration must not inherit the repo-local cookie model; it should use runtime secret injection such as release cookie configuration.
Cookie files must be `0600` or stricter and must not be printed in logs or templates.
Guarded source-dev BEAM targets require IPv4-literal host parts for CIDR validation.
When BEAM Runtime Endpoint mode is selected, BEAM connection failure must fail visibly rather than automatically falling back to gRPC for the same request.
gRPC remains an explicitly selected compatibility mode, not an implicit fallback behind BEAM mode.
Promotion starts with split-role `bin/dev-controller` and `bin/dev-node-agent` before changing all-in-one `bin/dev`.
The accepted smoke gate requires remote BEAM Runtime Endpoint RPC evidence, Console Nodes to show local and remote Node Agents reachable, `GET /v1/models` to return `200`, and `POST /v1/chat/completions` to complete through the Console Playground or an equivalent API request.
Before flipping source-dev defaults, record durable smoke evidence in sanitized form in the accepting change package, decision record, or promotion pull request, including date, commit, sanitized hosts, commands, target node names, pass/fail checklist, and remote Runtime Endpoint RPC evidence.
Standalone investigation or evidence documents are not committed to the repo; durable conclusions are promoted into decisions, specs, docs, or tests instead.
The recorded evidence must not include cookie material, credentials, raw local evidence logs, local tool session identifiers, or machine-specific filesystem paths.
Console Nodes live diagnostics use the configured Runtime Endpoint target list, so explicit BEAM Runtime Endpoint targets take precedence over legacy gRPC runtime client targets during that smoke.
Do not remove gRPC compatibility before BEAM Runtime Endpoint transport is explicitly promoted after that smoke.

Keep the Worker Runtime Interface separate.
The Node Agent may continue to use a local worker protocol for Python/MLX subprocesses.
The BEAM-first decision applies to first-party Controller-to-Node Agent communication.
It does not remove the local process/protocol boundary between the Node Agent and non-BEAM Worker Runtimes.

## Platform portability scope

ADR 0023 makes Controller Host and Node platform profiles explicit, and ADR 0026 makes normalized capability evidence independent of transport and operating system.
This decision remains transport-independent and applies to admitted first-party Runtime Endpoints across supported profiles.

The accepted Linux Controller target does not gain production BEAM admission from architecture approval or Linux compilation alone.
Production use requires ADR 0012 build provenance, certificate, Peer Grant, trusted-name, network, host-control, and mixed-platform acceptance gates to pass for that profile.
The existing macOS source-dev and production evidence remains valid only for the scope it actually proved.

## Consequences

This removes gRPC/protobuf as the durable Controller-to-Node Agent domain abstraction for first-party Elixir services.
It reduces transport duplication, generated-code surface, and domain-to-proto translation for the v1 path.
It keeps OTP semantics close to the Orchard services that already run on the BEAM.

The design still preserves an extension point for non-BEAM Runtime Endpoints.
Those endpoints should integrate through Runtime Endpoint adapters rather than forcing the first-party v1 path through an external-service protocol.
It also avoids extending BEAM trust to endpoints Orchard does not fully own.
The existing cluster proto surface should not be deleted solely because the durable domain model moves to Runtime Endpoint semantics or the first-party path moves to BEAM Distribution.
It may still become useful for external Runtime Endpoint adapters or compatibility bridges.

Node lifecycle remains first-party and Node-specific.
Runtime Endpoint Availability becomes the scheduler-facing availability concept for both first-party and future external endpoints.
Runtime Endpoint Observations remain durable scheduler and operator inputs even when live first-party communication uses BEAM monitoring.
The first-party v1 durable Model Placement identity remains Node-scoped under `SPEC.md` §§6.1 and 8.2.
Runtime Endpoint Observations project placement and capacity evidence without creating a different durable identity.
Any future external, non-Node Runtime Endpoint durable placement identity requires an accepted contract change.
Placement Capacity becomes a Runtime Endpoint Observation rather than a protobuf-specific `runtime_model_placements` field.
The queue and scheduling semantics from `gnhf/objective-fully-impl-369718` should be preserved while adapting their transport-specific shell.
The conservative unknown-capacity rule is part of that behavior, not a gRPC artifact.
Keep the existing `cluster_busy` error name for now, but define it as live Runtime Endpoint capacity exhaustion rather than a transport-specific node-cluster failure.

## SPEC.md impact

The `SPEC.md` update replaces prior gRPC-only runtime execution language with Runtime Endpoint semantics, current gRPC compatibility transport, guarded BEAM transport, node scheduling, node lifecycle, and model placement.
The update also reconciles the incoming gnhf concurrency semantics around Placement Capacity, `cluster_busy`, queue requeue under the original deadline, tenant FIFO, weighted round-robin, and unknown-capacity fail-closed behavior.
The OpenSpec change should treat `gnhf/objective-fully-impl-369718` as an architecture input and preservation dependency, not as implementation scope to merge inside the proposal.
This ADR records the decision rationale; `SPEC.md` remains the normative build contract.
