## Context

Orchard currently presents one macOS-native product profile as the system-wide architecture. The four OTP applications are mostly portable, but `orchard_cli` unconditionally compiles Darwin C helpers, the Controller release loads CLI code to execute Controller-authoritative commands, configuration defaults encode macOS paths and MLX, and the MLX package owns the otherwise reusable Worker Runtime protobuf contract. Root umbrella validation therefore requires Apple tooling even for Controller-only work.

The target product must preserve the existing Mac all-in-one, DMG/PKG, launchd, signing, air-gap, and managed Node Agent handover guarantees while adding Linux Controller Hosts and, later, Linux accelerator Nodes. Postgres remains durable truth, the Controller continues to schedule Runtime Endpoints, and the Node Agent continues to own worker subprocesses.

The first mixed-platform deployment target is a Linux Controller with operator-provided external Postgres dispatching to existing macOS Apple Silicon Nodes using the MLX runtime provider.
It becomes a supported profile only after portable control-plane, trust, transport, capability, release, and mixed-platform acceptance evidence passes.
This ordering proves the required seams before CUDA or Linux Node lifecycle work begins.

## Goals / Non-Goals

**Goals:**

- Define portable core modules and enforce inward-only dependency direction.
- Preserve `orchard_node_agent` as the portable Node orchestration core.
- Separate host lifecycle, hardware capability discovery, runtime execution, and packaging responsibilities.
- Make Worker Runtime contracts provider-neutral, versioned, generated, and independently owned.
- Move durable Controller authority behind authenticated Controller-owned operations used by Console and CLI.
- Normalize artifact, runtime, acceleration, device, memory, and failure vocabulary for heterogeneous scheduling.
- Establish Linux portability and provider conformance as required validation, with real platform acceptance retained.
- Reconcile `SPEC.md`, decisions, OpenSpec capabilities, documentation, tests, and implementation before behavior changes land.
- Define the target architecture without claiming that unimplemented Linux behavior is currently supported.

**Non-Goals:**

- Implement CUDA, ROCm, Linux accelerator discovery, or GPU driver management.
- Select final Linux packaging, service manager, desktop UI, or managed Postgres behavior.
- Replace BEAM Runtime Endpoints, Postgres durable truth, or the worker subprocess boundary.
- Introduce Kubernetes, runtime downloads, a backend gallery, or a plugin marketplace.
- Weaken macOS lifecycle, signing, notarization, rollback, retained-state, trust, or air-gap guarantees.

## Decisions

### 1. Platform profiles refine product support

The portable product contract describes Controller Hosts, schedulable Nodes, Node Agents, Runtime Endpoints, and runtime providers independently. Platform profiles then bind those roles to host lifecycle, paths, credential stores, packaging, and runtime payloads.

The macOS profile preserves all current behavior. The first Linux profile supports a Controller Host with external Postgres and no requirement to be a schedulable inference Node. A mixed cluster may contain that Linux Controller and macOS MLX Nodes.

**Alternative considered:** Replace the macOS product definition with a generic lowest-common-denominator contract. Rejected because it would obscure or weaken accepted Mac-specific operational guarantees.

### 2. Keep the existing portable OTP applications

`orchard_shared`, `orchard_controller`, `orchard_node_agent`, and `orchard_cli` remain the portable umbrella applications. `orchard_node_agent` gains injected host-process, capability-provider, and runtime-provider seams rather than being split into a new core application.

Platform host artifacts containing Darwin or future Linux native code must not become unconditional children of the portable umbrella. They are built and assembled only by their platform lanes.

**Alternative considered:** Extract `orchard_node_core`. Rejected because the current Node Agent has portable dependencies and already owns the correct supervision and worker boundary; extraction would add churn without removing a platform dependency.

### 3. Host lifecycle remains external to the managed Node Agent

A deep managed-host lifecycle interface hides service-manager and process-identity vocabulary. Its normative operations establish crash-released exclusion, observe start policy/service/process state independently, fence an exact instance to a proven stopped state, and launch one provisional authorized instance. Portable orchestration owns lifecycle state-machine decisions; adapters own platform mechanics and opaque non-reusable process identities.

The macOS adapter preserves launchd suppression, exact Darwin process identity, handover evidence, and one-shot acceptance. A Linux adapter must later prove equivalent invariants rather than translate `launchctl` calls mechanically.

**Alternative considered:** Move lifecycle into the Node Agent. Rejected because the actor being fenced, replaced, or stopped cannot independently own the exclusion and liveness proof required by managed handover.

### 4. Capability discovery and runtime execution are separate authorities

A capability provider reports host-observed device inventory, topology, memory domains, driver readiness, availability, and changing health. A runtime provider reports what its engine can initialize and use, model compatibility, runtime health, active allocation, and execution capacity. Dispatch eligibility requires compatible evidence from both authorities plus current Controller policy.

This prevents one worker process from defining all Node hardware facts and supports multiple runtime providers or devices on one host.

**Alternative considered:** Keep discovery entirely inside each worker. Rejected because hardware inventory would remain unavailable before worker startup, duplicate across providers, and conflate device health with runtime initialization.

### 5. Worker Runtime contract ownership is provider-neutral

Worker Runtime proto source, generated bindings, version rules, and conformance fixtures move to a provider-neutral repository location. The Node Agent maps the contract to its internal domain. MLX remains one implementation and no longer owns the protocol.

The existing operation set remains the compatibility baseline. Additive versioned capability negotiation identifies protocol version, provider identity/version, supported artifact formats and runtime features, acceleration implementations, device resources, memory semantics, concurrency, and cache features. Existing fields remain decodable during migration but cease to be authoritative where normalized replacements exist.

All supported bindings are generated from one source with a drift check.

**Alternative considered:** Create a new publishable package immediately. Rejected unless generation or artifact distribution later demonstrates a need; independent ownership does not require another OTP application.

### 6. Domain vocabulary separates four concepts

Orchard distinguishes:

- artifact format, such as GGUF or SafeTensors;
- runtime provider, such as MLX-LM or a future vLLM provider;
- acceleration implementation, such as Metal, CUDA, ROCm, or CPU;
- device resource, including identity, topology, memory domain, and allocatable capacity.

Scheduler and policy code consume normalized capabilities and resource requirements, never operating-system or provider-name conditionals. Provider-specific details may appear only in bounded diagnostics and profile configuration.

### 7. Controller owns durable operator authority

Operations that authoritatively read or mutate Controller-owned durable state execute inside the active Controller through authenticated, authorized, audited operations. Console and CLI use the same Controller-owned domain operations. The CLI owns argument parsing, client interaction, confirmation presentation, and output formatting; it does not own Ecto Repo authority.

A narrow Controller-owned local bootstrap/recovery channel may invoke the same domain operations when normal remote credentials do not yet exist. Host-local service, lifecycle, environment, trust-store, and support collection operations belong to platform host tooling.

**Alternative considered:** Preserve direct Repo CLI operations on co-resident hosts. Rejected because it prevents a remote portable CLI, duplicates authority, bypasses one transport/audit policy, and keeps the Controller release coupled to CLI implementation.

### 8. Portability is enforced by layered CI

Required Linux validation compiles and tests portable applications without Xcode, MLX, CUDA, launchd, or platform native helpers. Provider-neutral fake worker, capability, lifecycle, and scheduler conformance runs without accelerator hardware. Real macOS host, Apple Silicon MLX, Swift app, packaging, and publication lanes remain separate. Future Linux host and CUDA lanes are additive.

Triggers follow dependency ownership: shared contracts, proto, root configuration, toolchain, and release composition fan out to all consumers. Path filters may optimize only after ownership is clean and must not allow normative contract changes to skip applicable validation.

### 9. Contract acceptance and implementation acceptance are separate

This change establishes the normative target, ownership boundaries, migration order, and acceptance conditions.
It does not make Linux Controller support, a portable CLI, provider-neutral capability scheduling, or host adapters operational by itself.

Each implementation slice requires a linked child issue and a separate OpenSpec change when it changes behavior or architecture.
The Linux Controller profile becomes supported only after its release, trust, transport, scheduling, streaming, cancellation, restart, and failure acceptance passes with an admitted macOS MLX Node.

**Alternative considered:** Keep one 69-task OpenSpec change active through every implementation slice. Rejected because it would make contract review, behavior review, dependency ownership, and archival too coarse, and it would overlap active lifecycle, scheduling, and release-governance changes.

## Risks / Trade-offs

- **[Risk] The first Linux-green build exposes previously hidden assumptions.** → Introduce the lane after native eviction, characterize failures as portability gaps, and do not weaken the lane with broad skips.
- **[Risk] Moving CLI authority expands the remotely reachable operator surface.** → Migrate command families incrementally through explicit authorization, audit, leader, idempotency, confirmation, and secret-output contracts; retain a narrow local bootstrap channel.
- **[Risk] Capability normalization changes scheduling behavior.** → Add normalized evidence additively, compare decisions in diagnostics, then make it authoritative in a separate behavior slice with failure-path tests.
- **[Risk] Protocol version skew creates silent false eligibility.** → Treat absent, unknown, malformed, or stale capability evidence as unknown and fail closed for requirements it must prove.
- **[Risk] A new host adapter recreates umbrella contamination.** → Keep platform native artifacts outside unconditional portable compilation and validate the dependency rule in CI.
- **[Risk] General lifecycle vocabulary loses forensic detail.** → Persist normalized normative outcomes plus bounded platform-tagged evidence; translate legacy macOS records read-side without rewriting history.
- **[Risk] Mixed-platform BEAM operation expands the trust matrix.** → Require explicit build provenance, identity, transport, and mixed-platform acceptance before production admission; do not infer support from Linux compilation alone.

## Follow-up Delivery Plan

1. Amend `SPEC.md` with platform profiles, portable invariants, heterogeneous terminology, first Linux topology, and a new platform-expansion milestone; add or amend decisions before implementation.
2. Evict Darwin helpers from `orchard_cli`'s unconditional compiler path while preserving macOS host behavior and tests.
3. Add the required Linux portable and provider-neutral conformance lanes.
4. Move the packaged local command handler into `orchard_controller`, update the wrapper, and remove `orchard_cli` from the Controller release without changing command semantics.
5. Relocate Worker Runtime protocol ownership and generate both Elixir and Python bindings without wire changes.
6. Add capability negotiation, normalized resources, generic failure categories, and compatibility decoding; make eligibility authoritative only in its reviewed behavior slice.
7. Introduce the capability-provider seam and conformance implementations while preserving MLX runtime behavior.
8. Put existing managed macOS lifecycle behavior behind the host-lifecycle interface and migrate evidence additively.
9. Move Controller-authoritative CLI command families to authenticated Controller operations incrementally.
10. Add and accept the Linux Controller release profile and mixed Linux Controller/macOS MLX Node evidence. Linux Node and CUDA work follow separate changes.

The implementation steps above are follow-up changes under umbrella issue #266, not tasks in this contract-only change.
Each slice preserves a rollback path to the prior macOS behavior until its replacement passes equivalent Mac acceptance.
Additive schemas and protocol fields remain backward-decodable through the documented compatibility window.

## Open Questions

- Which Linux Controller distribution format and host manager should become supported after source/release portability is proven?
- Should Linux managed Postgres remain deferred beyond the first external-Postgres profile?
- Which command family should be the first authenticated CLI-to-Controller authority migration slice?
- When should deprecated MLX-named durable error and memory fields be removed after normalized replacements become authoritative?
