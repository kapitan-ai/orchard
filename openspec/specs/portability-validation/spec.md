# portability-validation Specification

## Purpose

Defines the validation lanes and dependency-driven gate selection required to prove Orchard's portable core, provider-neutral contracts, and platform-specific behavior without substituting one class of evidence for another.

## Requirements

### Requirement: Required Linux Portable Validation
Every non-documentation product change that can affect portable Orchard code SHALL run required Linux validation for portable application compilation, static analysis, tests, and coverage without Apple or accelerator toolchains.
The lane SHALL include the portable tokenizer workflow and Worker Runtime stubs that do not import accelerator implementations.

#### Scenario: Controller source changes
- **WHEN** a change modifies portable Controller behavior
- **THEN** required validation runs on Linux
- **AND** the validation does not provision Xcode, launchd, MLX, or CUDA

### Requirement: Provider-Neutral Conformance Validation
Orchard SHALL validate Worker Runtime, capability-provider, host-lifecycle invariant, Runtime Endpoint mapping, and scheduler capability contracts with fake or stub implementations that require no accelerator hardware.
Passing conformance MUST NOT be represented as real-hardware acceptance.

#### Scenario: Capability schema changes
- **WHEN** a change modifies normalized capability or resource semantics
- **THEN** provider-neutral conformance validates success, unknown, malformed, stale, and version-skew paths

### Requirement: Platform Acceptance Remains Separate
macOS host lifecycle, Apple Silicon MLX, Swift app, macOS packaging, and credentialed publication SHALL remain separate applicable lanes.
Future Linux host and CUDA acceptance SHALL be added as separate lanes when those profiles are proposed.
Fake or Linux portable validation MUST NOT replace real platform acceptance for platform-specific behavior.

#### Scenario: MLX provider behavior changes
- **WHEN** a change modifies the MLX runtime implementation or its provider mapping
- **THEN** provider-neutral conformance runs
- **AND** the Apple Silicon MLX acceptance lane runs

### Requirement: Validation Triggers Follow Dependencies
Validation selection SHALL follow owned dependency edges and contract fan-out rather than directory names alone.
Changes to shared contracts, proto source, root configuration, toolchain, release composition, normative product contracts, or a portable interface SHALL trigger every consuming lane needed to prove compatibility.
Documentation-only optimization MUST NOT classify a normative `SPEC.md` or OpenSpec contract change as ordinary prose that skips applicable validation.

#### Scenario: Worker protocol changes
- **WHEN** the provider-neutral Worker Runtime protocol changes
- **THEN** portable binding and conformance lanes run
- **AND** every supported runtime-provider acceptance lane runs

### Requirement: Required Gate Aggregates Conditional Lanes
The required repository gate SHALL fail when any applicable portable, conformance, platform, or packaging lane fails and SHALL succeed when every applicable lane passes or is explicitly inapplicable under the dependency rules.

#### Scenario: Controller-only portable change
- **WHEN** dependency classification proves that no platform implementation or packaging contract is affected
- **THEN** the required gate may omit expensive platform lanes
- **AND** it still requires the Linux portable and applicable conformance lanes
