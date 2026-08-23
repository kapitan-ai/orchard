## Why

Orchard's current product contract and build ownership make macOS, launchd, Xcode tooling, and MLX assumptions apply to the entire umbrella even though the Controller, shared domain, CLI client behavior, and Node Agent orchestration core are structurally portable.
Orchard needs an explicit platform-portability contract now so Linux Controller support and future Linux accelerator runtimes can be added without weakening the existing macOS all-in-one product or repeating platform conditionals throughout portable code.

This contract change amends `SPEC.md`: Apple Silicon macOS with MLX becomes the current supported platform profile rather than the definition of every Controller Host and Node.
Linux Controller with external Postgres plus existing macOS MLX Nodes becomes the first accepted mixed-platform target, but support is not declared until its later implementation and acceptance milestone passes.

## What Changes

- Define portable Orchard core responsibilities and inward-only dependency rules for `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and the remote-capable `orchard_cli` client.
- Define platform profiles that preserve macOS all-in-one operation while adding Linux Controller Hosts and heterogeneous schedulable Nodes.
- Separate artifact format, runtime provider, acceleration implementation, and device-resource capability vocabulary.
- Establish provider-neutral, versioned Worker Runtime contract ownership outside the MLX implementation while preserving the Node Agent-owned subprocess boundary.
- Establish separate host-lifecycle and capability-provider interfaces so launchd/Darwin, future Linux host management, Apple hardware discovery, and future NVIDIA/AMD discovery remain outside portable core modules.
- Move Controller-state authority behind Controller-owned authenticated operations shared by Console and CLI clients; retain only a narrow Controller-owned local bootstrap/recovery channel.
- Establish the target contract that removes direct Controller Repo authority and Darwin native helper compilation from the portable CLI; host-local lifecycle operations become platform-host tooling after separately reviewed migrations.
- Require a Linux portability validation lane for portable code, provider-neutral conformance validation, and separate platform acceptance and packaging lanes.
- Preserve macOS app, DMG, PKG, launchd, managed Node Agent handover, signing, notarization, air-gap, and operator-state-retention guarantees within the macOS profile.
- Defer CUDA implementation, Linux GPU driver management, final Linux Node packaging, final Linux Controller packaging, managed Linux Postgres, and remotely downloadable runtime catalogs.
- Keep native relocation, CI restructuring, protocol and schema changes, CLI migrations, and Linux release implementation outside this contract-only change.

## Capabilities

### New Capabilities

- `platform-profiles`: Defines portable Orchard roles, supported host/node profiles, dependency direction, Mac all-in-one preservation, and the first Linux Controller mixed-platform topology.
- `host-lifecycle-adapters`: Defines platform-neutral managed-host lifecycle invariants and the adapter seam for macOS launchd and future Linux host implementations.
- `worker-runtime-providers`: Defines provider-neutral Worker Runtime contract ownership, protocol versioning, normalized runtime/device vocabulary, capability negotiation, and provider conformance.
- `operator-command-authority`: Defines Controller-owned operator authority, portable CLI client responsibilities, host-local operation ownership, and the narrow local bootstrap/recovery channel.
- `portability-validation`: Defines Linux portable validation, provider conformance, platform acceptance, packaging lanes, and dependency-aware trigger requirements.

### Modified Capabilities

- `runtime-endpoints`: Runtime Endpoint Observations and Node Agent status gain normalized platform, runtime-provider, device-resource, and capability-version evidence without changing the Controller-to-Node Runtime Endpoint boundary.
- `scheduler`: Production eligibility and placement must consume normalized artifact/runtime/device capabilities rather than backend or operating-system strings.
- `packaging-deployment`: The existing DMG/PKG/launchd requirements become explicitly macOS-profile requirements while generic, secret-free distribution and role compatibility remain cross-profile invariants.

## Impact

- Normative changes to `SPEC.md` platform assumptions, topology, Node identity/capabilities, runtime requirements, scheduling eligibility, packaging/deployment, lifecycle, security storage examples, milestone acceptance, and implementation roadmap.
- New decision records for platform profiles, CLI/Controller authority, Worker Runtime contract ownership, and capability-provider separation; scoped amendments to existing macOS, runtime, trust, and managed-handover decisions.
- Follow-up refactoring across root release composition, CLI dependencies and native compilation, Controller command execution, Node Agent adapter injection, worker protobuf ownership/generation, model/runtime vocabulary, configuration defaults, and Console labels.
- Follow-up CI changes from one Apple Silicon validation job to Linux portable and conformance gates plus macOS host, MLX, Swift, packaging, and publication lanes; future CUDA/Linux host lanes remain additive.
- Existing public inference APIs, Postgres durable truth, Runtime Endpoint transport semantics, Mac all-in-one behavior, and current macOS distribution guarantees remain in scope and must not regress.
- This change itself modifies contracts and documentation only; it does not declare the Linux profile supported or change application, schema, runtime, packaging, or CI behavior.
