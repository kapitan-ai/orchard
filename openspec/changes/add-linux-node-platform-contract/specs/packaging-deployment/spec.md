## MODIFIED Requirements

### Requirement: Distribution Payloads Are Selected Explicitly

A distribution profile SHALL contain only runtime providers and native host
artifacts compatible with its declared platform and runtime-provider profiles.
The macOS native distribution profile SHALL retain the accepted Controller,
Node Agent, MLX, tokenizer, app-owned host lifecycle, and role-selected payload
behavior for the all-in-one topology until a separately accepted change
supersedes it.

The experimental `ubuntu_24_04_x86_64_node` candidate SHALL produce a Node-only
Debian artifact containing the portable Node Agent release, required shared
portable libraries, Linux lifecycle assets, and no Controller, Console,
database, macOS, MLX, CUDA, ROCm, or provider-specific payload unless a separate
profile explicitly adds and qualifies it. Package construction or local
installation SHALL NOT authorize publication or a support claim.
The artifact SHALL bundle its exact ERTS and OTP release runtime and SHALL NOT
require host-installed Erlang or Elixir.
Every remaining host dependency SHALL have an accepted version constraint in a
machine-readable package dependency manifest, and preflight SHALL reject an
incomplete or incompatible closure before mutation.
Online and air-gapped installation SHALL use the same dependency closure, with
air-gapped media requiring no public download.

#### Scenario: Mac all-in-one artifact is assembled

- **WHEN** the existing macOS all-in-one topology is built during the portability migration
- **THEN** it continues to contain the accepted Mac-compatible role payloads
- **AND** no future Linux or CUDA payload is required for acceptance

#### Scenario: Linux Node package contains Controller code

- **WHEN** assembled package closure contains a Controller application or database role
- **THEN** package validation fails
- **AND** role selection at runtime cannot excuse the invalid closure

#### Scenario: Linux Node package has no provider payload

- **WHEN** the provider-neutral first package is assembled
- **THEN** it can install and run model-free Node Agent lifecycle tests
- **AND** no accelerator runtime is required or implied

#### Scenario: Clean host lacks a declared dependency

- **WHEN** package preflight cannot satisfy the versioned dependency manifest
- **THEN** installation fails before filesystem, identity, or service mutation
- **AND** it does not download an undeclared dependency
