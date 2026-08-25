## Context

Orchard's portability contract was accepted in the archived `establish-platform-portability-contract` change and then narrowed by the archived `remove-native-pkg-distribution` change.
Both used `platform profile` as a single umbrella term covering operating system support, deployment artifacts, runtime providers, and cross-host acceptance, and both used `portable core` without saying which components it names.
`SPEC.md`, contributor docs, operator docs, decisions, the glossary, and accepted OpenSpec specs therefore described four different concerns with one word, and described an approved distribution design as an available one.

## Goals

- Give the portable boundary one explicit name that lists its member components and its provider-neutral contracts.
- Give each profile kind a qualified name so a reader can tell operating system support from deployment artifacts, runtime providers, and acceptance topologies.
- Keep the approved macOS native distribution design intact while removing the implication that a supported public binary already exists.
- Keep every macOS contract lane separate and keep credentialed release operations release-only.
- Record the reconciliation in a purpose-named change package rather than reopening a completed one.

## Non-Goals

- Change Orchard's legal licensing posture.
- Introduce an `orchard_node_core` abstraction or any other new umbrella application.
- Restore native PKG distribution or a managed Node Agent handover protocol.
- Change product code, tests, or CI workflow definitions.
- Claim Linux Node support or a supported Linux Controller before Milestone 8 acceptance.

## Decisions

### Qualified Profiles Replace The Umbrella Term

A platform profile binds host roles to an operating system, architecture, and platform acceptance evidence.
A distribution profile binds a platform profile and install roles to deployment artifacts, host lifecycle, paths, credential storage, update and rollback behavior, retained state, and release evidence.
A runtime-provider profile binds a Node role to a Worker Runtime provider, compatible acceleration and device resources, provider-neutral conformance, and real-runtime acceptance.
An acceptance profile names a topology and the evidence required to prove its participating profiles operate together.
Host-lifecycle adapters and deployment artifacts are implementation boundaries and artifacts, so they are not profiles.
A runtime-provider profile qualifies the Node role it applies to and does not make the portable Node Agent provider-specific.

### Profile Definition And Topology Identity Do Not Imply Support

Defining or accepting a profile names its contract target without declaring it supported.
Support requires the applicable acceptance evidence and gates to pass.
Topology identity is also orthogonal to Database Mode and milestone status.
The current app-installed all-in-one path requires external Postgres, split-role source development is validated, packaged multi-Mac operation remains a first-cut rehearsal path, Managed Database Mode remains future Milestone 6 work, and Active/Standby operation remains a Milestone 7 target.

### The Portable Boundary Is Named For What It Contains

The portable Orchard control-plane core is the platform-neutral behavior of `orchard_shared`, `orchard_controller`, `orchard_node_agent`, and the portable `orchard_cli`, together with the provider-neutral contracts they depend on.
Naming the members keeps the boundary reviewable without introducing a new application or module.

### Approved Distribution Design Is Not A Public Binary Promise

The signed and notarized DMG containing `Orchard.app` remains the approved macOS native distribution design.
The initial source-availability transition does not promise a supported public binary.
A supported public binary requires an explicit release decision and completion of every applicable build, verification, signing, notarization, stapling, and publication gate.
Source availability also does not change Orchard's licensing terms, which this change leaves exactly as they are.

### The Completed PKG-Removal Package Keeps Its Original Scope

The archived `remove-native-pkg-distribution` package stays as the historical record of the native PKG and managed handover removal decision.
The source-first and qualified-profile decisions are recorded here instead, so the archive keeps reproducing the decision that was actually reviewed and accepted at the time.

## Alternatives Considered

- Amend the archived `remove-native-pkg-distribution` package in place: rejected because it would rewrite an accepted record with decisions its reviewers never saw.
- Keep `platform profile` as an umbrella term and qualify it only in prose: rejected because the accepted specs and `SPEC.md` would still normatively use one word for four concerns.
- Introduce an `orchard_node_core` application to carry the portable boundary: rejected because the boundary is a documentation and dependency-direction contract, not a new deployable unit.

## Migration Plan

1. Rename the dependency requirement to the portable Orchard control-plane core and define the four qualified profile kinds in `platform-profiles`.
   Separate profile definition and topology identity from support status and milestone acceptance.
2. Scope the Apple distribution gates and payload selection requirements in `packaging-deployment` to the macOS native distribution profile, and add the source availability requirement.
3. Split the macOS contract lanes in `portability-validation` and keep credentialed release operations release-only.
4. Requalify the portable boundary reference in `host-lifecycle-adapters` and the provider support trigger in `worker-runtime-providers`.
5. Requalify the `app-distribution-lifecycle` Purpose prose without changing its requirements.
   OpenSpec delta grammar does not model Purpose-only edits, so the proposal Impact and task 1.7 record the provenance without a no-op requirement delta.
6. Reconcile `SPEC.md`, `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, decisions, glossary, architecture, tooling, local development, process, and packaging documentation with the same vocabulary.
7. Validate this change strictly while it is active, then archive it without reapplying already synchronized accepted specs.

## Risks And Mitigations

- Risk: readers treat the renamed requirements as new behavior.
  Mitigation: every rename is declared explicitly and the deltas carry the full modified bodies.
- Risk: the qualified vocabulary drifts back to the umbrella term in later changes.
  Mitigation: the glossary records the qualified terms with explicit avoid lists, and the accepted specs state that adapters and artifacts are not profiles.
- Risk: the source-first statement is read as withdrawing the DMG design.
  Mitigation: the added requirement states that the approved Orchard.app-inside-DMG design remains unchanged.
