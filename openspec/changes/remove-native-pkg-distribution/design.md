## Context

Orchard currently has an implemented app-owned macOS lifecycle distributed through a signed DMG and native PKG material that still carried active normative support claims.
ADR 0018 layered a broad zero-overlap Managed Node Agent replacement protocol over both paths, but the protocol was not implemented and the PKG `preinstall` behavior contradicted the normative ordering.
The repository must distinguish current support from historical or inactive material without removing source development, APIs, or Orchard.app/DMG.

## Goals

- Align `SPEC.md`, accepted OpenSpec specs, active changes, decisions, security guidance, contributor guidance, and operator docs on Orchard.app/DMG as the current native distribution.
- Remove current native PKG support and Managed Node Agent zero-overlap handover claims.
- Preserve app lifecycle rollback, retained state, signing, DMG verification, source development, supported APIs, and rolling-version compatibility.
- Make future packaging or managed handover require fresh explicit review and implementation.

## Non-Goals

- Delete historical archives or remove the app's legacy PKG receipt blocker.
- Change Orchard.app lifecycle implementation, DMG assembly, launchd service definitions, source-development commands, API behavior, wire contracts, or persisted data.
  `orchardctl start` gains one launchd job-domain call for upgrade compatibility; see the decision below.
- Define a replacement Managed Node Agent handover protocol.
- Claim Linux distribution or Linux Node lifecycle support.

## Decisions

### Orchard.app/DMG Is The Current Native Distribution

The signed and notarized DMG containing `Orchard.app` remains the current macOS distribution.
The app-owned root-authorized lifecycle remains responsible for role-aware install, update, uninstall, status, transactional rollback, and retained operator state.
Release sidecars, inner-first signing, mounted-DMG verification, and Amore handoff remain unchanged.

### Native PKG Has No Current Support Authority

Native PKG is removed from release artifacts, install and upgrade workflows, offline flows, validation gates, platform-profile acceptance, and contributor command guidance.
PKG implementation code, scripts, package assets, dedicated tests, and active operator documentation are deleted.
The app retains only the legacy receipt blocker needed to prevent silent ownership takeover of an existing installation.

### ADR 0018 Is Superseded Without A Replacement Guarantee

ADR 0018 remains readable as historical context, but its status points to ADR 0027 and its protocol no longer appears in active specifications or glossary terms.
The contract does not replace zero-overlap with an implicit weaker guarantee.
Controller `N` compatibility with Node Agent `N` and `N-1` remains a protocol compatibility rule for sequential rolling upgrades and does not authorize concurrent access to one Node Identity Root.

### `orchardctl start` Clears Legacy Job-Domain Disablement

Removing the handover also removed `LifecycleSystem.disable_job/2`, so `orchardctl stop` no longer applies persistent launchd job-domain disablement.
An install upgraded from an older Orchard can still carry disablement that an earlier `orchardctl stop` applied, and `launchctl bootstrap` alone does not clear it, so that host would silently fail to start.
`orchardctl start` therefore runs `launchctl enable system/<label>` before `launchctl bootstrap` for every selected service.

Two consequences are accepted deliberately rather than incidentally:

- The enable is unconditional, so `orchardctl start` also overrides an operator's own `launchctl disable`. Job-domain disablement is not a supported way to keep an Orchard service down; leaving it stopped or removing the role from the install is.
- A nonzero `launchctl enable` fails the start before bootstrap is attempted, because the alternative is bootstrapping a job the domain will refuse to run and reporting success.

`packaging/README.md` documents both, together with the matching consequence that `orchardctl stop` no longer survives a reboot or launchd domain reload.

### Reintroduction Requires A Fresh Proposal And Pull Request

A future native package, additional distribution channel, or managed replacement protocol starts with a fresh OpenSpec proposal.
A separate implementing pull request must reconcile `SPEC.md`, decisions, accepted specs, security posture, operator documentation, artifact governance, and validation gates before support is claimed.
Legacy files, archived changes, and superseded decisions are research input only.

## Reconciliation Strategy

1. Remove native PKG and handover requirements from `SPEC.md` while retaining app/DMG and source/API contracts.
2. Reconcile the accepted `packaging-deployment`, `app-distribution-lifecycle`, `host-lifecycle-adapters`, and `platform-profiles` specs.
3. Delete the abandoned active `managed-node-agent-handover` change rather than archive it.
4. Supersede ADR 0018 through ADR 0027 while preserving ADR 0018's historical body.
5. Reconcile active change packages that still assume PKG artifacts or handover behavior.
6. Update contributor, tooling, process, architecture, glossary, security, local-development, and operator guidance.
7. Validate the change strictly and classify residual matches as superseded history, archived history, explicit non-support language, legacy receipt compatibility, or unrelated vocabulary.

## Risks And Mitigations

- **Legacy receipt compatibility may be mistaken for support.** Active specs and docs state that receipt detection prevents ownership takeover and does not provide an installation path.
- **Removing the handover protocol may be read as permitting overlap.** The contract explicitly says compatibility does not authorize concurrent use of one Node Identity Root and makes no replacement safety guarantee.
- **Future packaging may reuse stale assumptions.** The fresh-proposal and separate-PR gate requires renewed security, lifecycle, artifact, and validation design.
- **Historical records may appear contradictory.** ADR 0018 and related historical material remain intact but are clearly classified as superseded or archived.
- **Deleting PKG tests could silently drop coverage of retained code.** Wrapper and payload-signing regression suites are retained against `packaging/payload/bin/` and the retained signing scripts, and the payload build gate runs the real build rather than inspecting help text.
- **Deleting the PKG runbook could strand operator guidance.** Installer-independent transport, TLS, CORS, Console, and upgrade-rollout documentation moves into `packaging/README.md` rather than disappearing with the PKG-specific material.

## Validation

Run strict validation for `remove-native-pkg-distribution` and then strict validation for all active and accepted OpenSpec material.
Run residual searches across active normative and operator-facing files for PKG and handover terms.
Inspect each remaining match and classify it rather than deleting historical evidence or unrelated vocabulary.
