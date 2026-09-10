## ADDED Requirements

### Requirement: Reasoning-effort evidence distinguishes mapping, conformance, qualification, and support

A local-model qualification record or support claim that names a reasoning-effort tier SHALL follow `docs/model-qualification.md` and identify the canonical tier, exact artifact/template renderer mapping, and exact tested tuple. Static mapping acceptance, Runtime Endpoint conformance, semantic tier qualification, and an approved scoped support claim SHALL remain separate evidence boundaries. Neither static rendering nor manual qualification MAY replace Runtime Endpoint dispatch proof.

#### Scenario: Static mapping succeeds

- **WHEN** an exact template renderer accepts a provider-specific value for a canonical tier
- **THEN** the record classifies that result as static mapping evidence only
- **AND** it does not represent semantic support, runtime dispatch authority, or an active support claim

#### Scenario: A tier cannot prove non-empty reasoning across its envelope

- **WHEN** semantic qualification shows that an exact tuple's tier can complete without valid non-empty reasoning content for a claimed prompt class
- **THEN** the record classifies that tier as `unsupported` for that exact tuple
- **AND** the tier is not offered or represented as supported rather than being absorbed as a terminal conformance failure
- **AND** the record does not become Runtime Endpoint capability, a scheduling fact, or dispatch authority, because runtime advertisement separately proves only renderer mapping and protocol conformance

#### Scenario: Qualified support claim names a tier

- **WHEN** an approved claim represents a reasoning-effort tier
- **THEN** it identifies only the exact approved tuple and tested endpoint envelope
- **AND** it does not generalize the provider mapping or tier outcome to another artifact, template, runtime, or environment
