# ADR: Platform profiles refine Orchard's portable core

## Status

Accepted on 2026-08-23 under issues #266 and #267.

## Context

`SPEC.md` historically defines Orchard as one Apple Silicon macOS product with launchd, Apple packaging, and MLX requirements applied to the whole umbrella.
The current repository already has useful portable boundaries, but `orchard_cli` unconditionally compiles Darwin helpers, macOS defaults reach portable configuration, and release composition mixes platform-specific payloads with portable applications.

Orchard needs a path to Linux Controller Hosts and later Linux accelerator Nodes without weakening the accepted macOS product or scattering operating-system conditionals through portable code.
Portable compilation alone is not sufficient evidence for supported deployment.

## Decision

Define a portable Orchard core and bind it to supported platform profiles.

The portable core consists of `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and portable `orchard_cli` behavior.
These applications SHALL depend on portable contracts for platform-neutral behavior.
Platform host adapters, runtime-provider implementations, platform packaging, and vendor SDKs SHALL depend inward on those contracts and MUST NOT become unconditional compile dependencies of the portable umbrella.

Keep `orchard_node_agent` as the portable Node orchestration core.
Do not extract an `orchard_node_core` application unless a later concrete dependency or supervision constraint requires it.

Treat Controller Hosts and schedulable Nodes as distinct roles.
A Controller Host does not become schedulable unless an admitted Node Agent on that host separately satisfies the Node trust, lifecycle, health, capability, and capacity contracts.

The current supported platform profile remains Apple Silicon macOS.
It preserves the all-in-one and split-role topologies, launchd, Orchard.app, DMG, PKG, managed handover, signing, notarization, air-gap, retained-state, managed Postgres, and MLX guarantees already accepted by `SPEC.md`.

The first accepted platform-expansion target is a Linux Controller Host with operator-provided external Postgres dispatching to admitted macOS Apple Silicon Nodes using the MLX runtime provider.
The Linux Controller profile is headless and does not require a local Node Agent or accelerator runtime.
It SHALL NOT be declared supported until its release, trust, transport, scheduling, streaming, cancellation, restart, failure, provenance, and mixed-platform acceptance passes.

Final Linux packaging, host management, managed Postgres, Linux Node lifecycle, Linux accelerator discovery, and CUDA or ROCm runtime support remain deferred.

## Consequences

The repository gains an enforceable dependency direction and a sequence for proving portability before adding another accelerator stack.
Mac-specific operational guarantees remain visible instead of being reduced to a lowest-common-denominator abstraction.
CI and release composition must later separate portable validation from platform acceptance and publication.
Every new platform or runtime profile requires explicit contracts and acceptance evidence.

The architecture contract may be accepted before implementation, but support status cannot.
The vNext milestone carries the support gate and preserves completed v1 macOS acceptance as historical truth.

## SPEC.md impact

Update required in the document preamble, §§1.1–1.5, 2, 4.1, 11, and 14.
