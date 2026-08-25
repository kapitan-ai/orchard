# ADR: Qualified profiles refine the portable Orchard control-plane core

## Status

Accepted on 2026-08-23 under issues #266 and #267.
Terminology reconciled on 2026-08-25 without changing the accepted dependency boundary.
ADR 0027 supersedes only this record's preservation of native PKG distribution and ADR 0018 managed handover; the portable Orchard control-plane core and qualified-profile decision remains accepted.

## Context

`SPEC.md` historically defines Orchard as one Apple Silicon macOS product with launchd, Apple packaging, and MLX requirements applied to the whole umbrella.
The current repository already has useful portable boundaries, but `orchard_cli` unconditionally compiles Darwin helpers, macOS defaults reach portable configuration, and release composition mixes platform-specific payloads with portable applications.

Orchard needs a path to Linux Controller Hosts and later Linux accelerator Nodes without weakening the accepted macOS product or scattering operating-system conditionals through portable code.
Portable compilation alone is not sufficient evidence for supported deployment.

## Decision

Define the portable Orchard control-plane core and bind it to qualified, composable profiles.

The portable Orchard control-plane core consists of the platform-neutral behavior of `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and portable `orchard_cli`, together with the provider-neutral contracts on which they depend.
These applications SHALL depend on portable contracts for platform-neutral behavior.
Platform host adapters, runtime-provider implementations, platform packaging, and vendor SDKs SHALL depend inward on those contracts and MUST NOT become unconditional compile dependencies of the portable umbrella.

Keep `orchard_node_agent` inside the portable Orchard control-plane core as the Node orchestration participant.
Do not extract an `orchard_node_core` application unless a later concrete dependency or supervision constraint requires it.

Treat Controller Hosts and schedulable Nodes as distinct roles.
A Controller Host does not become schedulable unless an admitted Node Agent on that host separately satisfies the Node trust, lifecycle, health, capability, and capacity contracts.

Use four qualified, composable profile kinds: platform, distribution, runtime-provider, and acceptance.
`SPEC.md` §1.4 "Qualified profiles and portable assumptions" is the normative definition of each kind, and the "Product Truth" section of `docs/glossary/CONTEXT.md` carries the shared vocabulary; this record does not restate either.
The trade-off is deliberate: four kinds cost more vocabulary than one unqualified "profile", and in exchange platform support, deployment artifacts, runtime-provider support, and cross-platform acceptance stay separately claimable instead of one qualified profile silently implying the others.
Host-lifecycle adapters remain platform integration boundaries, while Orchard.app and DMG remain deployment artifacts.
Neither is a profile.

The current supported platform profile remains Apple Silicon macOS.
The macOS native distribution profile preserves Orchard.app inside a DMG, launchd, Keychain, app-owned lifecycle, rollback, retained state, signing, notarization, stapling, and air-gap guarantees already accepted by `SPEC.md`.
The macOS MLX Node runtime profile qualifies a Node role that pairs the portable Node Agent with Apple Silicon, Metal, MLX-LM, the tokenizer stack, provider-neutral conformance, and real-runtime qualification.
The Node Agent stays part of the portable Orchard control-plane core rather than becoming provider-specific.
ADR 0027 removes native PKG and managed Node Agent handover from these current profiles without weakening Orchard.app and DMG lifecycle requirements.

The first accepted platform-expansion target is a Linux Controller Host with operator-provided external Postgres dispatching to admitted macOS Apple Silicon Nodes using the MLX runtime provider.
The Linux Controller profile is a headless platform profile and does not require a local Node Agent, accelerator runtime, Xcode, launchd, Keychain, Orchard.app, or DMG.
The mixed-platform acceptance profile proves a portable Controller, including the Linux Controller, operating admitted macOS Nodes under the macOS MLX Node runtime profile.
The Linux Controller profile SHALL NOT be declared supported until its release, trust, transport, scheduling, streaming, cancellation, restart, failure, provenance, and mixed-platform acceptance passes.

Final Linux packaging, host management, managed Postgres, Linux Node lifecycle, Linux accelerator discovery, and CUDA or ROCm runtime support remain deferred.

## Consequences

The repository gains an enforceable dependency direction and a sequence for proving portability before adding another accelerator stack.
Mac-specific operational guarantees remain visible instead of being reduced to a lowest-common-denominator abstraction.
CI must later move broad portable validation to Linux and keep macOS host-lifecycle, Orchard.app/DMG, and MLX evidence in separate applicable lanes.
Credential-free signing-contract validation may run in normal CI, while Developer ID signing, notarization, stapling, and publication remain release-only.
Every new platform, distribution, runtime-provider, or acceptance profile requires explicit contracts and acceptance evidence.

The architecture contract may be accepted before implementation, but support status cannot.
The vNext milestone carries the support gate and preserves completed v1 macOS acceptance as historical truth.

## SPEC.md impact

Update required in the document preamble, §§1.1–1.5, 2, 4.1, 11, and 14.
