## MODIFIED Requirements

### Requirement: Distribution Payloads Are Selected Explicitly

A distribution profile SHALL contain only runtime providers and native host
artifacts compatible with its declared platform and runtime-provider profiles.
The macOS native distribution profile SHALL retain the accepted Controller,
Node Agent, MLX, tokenizer, app-owned host lifecycle, and role-selected payload
behavior for the all-in-one topology until a separately accepted change
supersedes it.

The experimental `ubuntu_24_04_x86_64_node` and
`ubuntu_26_04_x86_64_node` candidates SHALL use the Node-only Debian artifact
design containing the portable Node Agent release, required shared portable
libraries, Linux lifecycle assets, and no Controller, Console, database, macOS,
MLX, CUDA, ROCm, or provider-specific payload unless a separate profile
explicitly adds and qualifies it. Package construction or local installation
SHALL NOT authorize publication or a support claim.
The artifact SHALL bundle its exact ERTS and OTP release runtime and SHALL NOT
require host-installed Erlang or Elixir.
Each candidate SHALL have its own accepted, machine-readable host dependency
closure and fail-closed preflight. Online and air-gapped installation SHALL use
the same candidate-specific closure and exact package bytes. A dependency or
command implementation admitted for one candidate SHALL NOT be assumed for the
other. This requirement changes `SPEC.md` §11.

#### Scenario: Mac all-in-one artifact is assembled

- **WHEN** the existing macOS all-in-one topology is built during the portability migration
- **THEN** it continues to contain the accepted Mac-compatible role payloads
- **AND** no future Linux or CUDA payload is required for acceptance

#### Scenario: Linux Node package contains Controller code

- **WHEN** an assembled candidate package closure contains a Controller application or database role
- **THEN** package validation fails
- **AND** role selection at runtime cannot excuse the invalid closure

#### Scenario: Package bytes are reused across candidates

- **WHEN** byte-identical Node package payloads are proposed for both candidates
- **THEN** each candidate still requires its own dependency closure, preflight, and lifecycle evidence
- **AND** package identity alone does not establish host compatibility

#### Scenario: Air-gapped 26.04 media is incomplete

- **WHEN** the 26.04 media lacks any exact dependency or command implementation required by its accepted closure
- **THEN** installation fails before filesystem, identity, or service mutation
- **AND** it does not use public egress or borrow the 24.04 closure
