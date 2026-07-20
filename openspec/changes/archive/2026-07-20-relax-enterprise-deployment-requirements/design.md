## Context

Orchard currently describes its macOS packaging model as both a local installer path and an enterprise deployment path.
The local installer need is still real because Orchard installs LaunchDaemons, root-owned support directories, wrapper scripts, and shared service state.
The enterprise deployment requirement is no longer grounded in current user demand.
Keeping MDM/Jamf as a required v1 surface makes distribution decisions look more constrained than they need to be.

## Goals / Non-Goals

**Goals:**

- Keep the packaging contract aligned with actual near-term demand.
- Preserve a root-authorized installer path for launchd-backed controller and node-agent services.
- Preserve repeatable local install and upgrade flows for development, testing, pilot installs, and offline transfer.
- Remove MDM/Jamf-specific acceptance language from SPEC.md and packaging docs.
- Make future enterprise deployment an explicit later option rather than an implied v1 promise.

**Non-Goals:**

- This change does not remove PKG packaging by itself.
- This change does not introduce a new Amore, Sparkle, DMG, Homebrew, or updater workflow.
- This change does not change launchd service installation, role selection, TLS guardrails, licensing activation, or offline model import behavior.
- This change does not implement managed Postgres.

## Decisions

### Decision: Keep PKG For Privileged Local Installation

Orchard will continue to use PKG where the installer needs root authorization, launchd plist installation, system support directories, preinstall and postinstall scripts, and deterministic ownership or mode handling.
The alternative was to move immediately to a `.app` or DMG-only shape.
That does not fit the current service model unless Orchard also stops installing machine-level daemons and shared root-owned state.

### Decision: Remove MDM/Jamf As Current Requirements

SPEC.md and packaging docs will stop saying that v1 PKG support includes MDM deployment, Jamf deployment, or enterprise managed-device workflows.
The alternative was to keep them as latent requirements because PKG can support them.
That keeps unnecessary constraints in the product contract and obscures the simpler reason PKG exists.

### Decision: Keep Unattended Local Installer Support

The `installer -pkg ... -target /` path remains useful for local automation, repeatable smoke tests, and offline or scripted operator workflows.
The alternative was to remove all unattended language with MDM.
That would throw away a useful local invariant even though managed-device deployment is the part being dropped.

### Decision: Keep Generic Artifact And Activation Separation

Distribution artifacts remain generic.
License activation, customer attribution, database configuration, and deployment-specific secrets stay outside the package payload and out of reusable distribution metadata.
The alternative was to simplify docs by mixing activation examples into distribution channels.
That would weaken the existing secret-handling posture.

## Risks / Trade-offs

- Operators may still ask later for MDM/Jamf support -> Mitigation: keep the current PKG design compatible enough that managed deployment can be reintroduced as a separate change.
- Removing enterprise language may make PKG feel less justified -> Mitigation: SPEC.md should state the root-authorized launchd/service installation reason directly.
- Docs may leave stale Jamf or MDM references behind -> Mitigation: search SPEC.md, packaging docs, and glossary for managed deployment terms during implementation.
- Homebrew language may blur into managed deployment -> Mitigation: keep Homebrew as optional future or informal install convenience unless separately approved.

## Migration Plan

1. Update SPEC.md §11 Packaging and Deployment to remove MDM as required behavior.
2. Update packaging docs so Jamf, MDM, private casks, and enterprise deployment examples are no longer presented as current supported requirements.
3. Keep existing scripts unchanged unless tests reveal a hard-coded managed deployment assumption.
4. Validate the OpenSpec change strictly before implementation handoff.

Rollback is a documentation and contract revert.
If enterprise deployment becomes a requirement again, add a dedicated change with explicit user demand and acceptance criteria.

## Open Questions

- Should private Homebrew cask guidance remain as a convenience note, or should it also move fully to future work?
- Should DMG work now mean a simple interactive wrapper around the PKG, or should the product shape be revisited before adding DMG polish?
