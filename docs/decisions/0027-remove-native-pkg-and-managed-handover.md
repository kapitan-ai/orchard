# ADR: Remove native PKG distribution and managed Node Agent handover

## Status

Accepted on 2026-08-24.

Supersedes ADR 0018.
Supersedes only the native PKG and managed-handover preservation clause in ADR 0023; ADR 0023's portable-core and platform-profile decision remains accepted.

## Context

Orchard currently has two competing macOS distribution stories.
The signed `Orchard.app` in the DMG has an implemented app-owned lifecycle, while the native PKG path remains repository material with contract claims that exceed its implemented safety and validation.

ADR 0018 and the abandoned `managed-node-agent-handover` OpenSpec change specified a large zero-overlap replacement protocol across Orchard.app, PKG, recovery, start, and stop paths.
That protocol was not implemented, and keeping it normative made `SPEC.md` disagree with the current lifecycle and installer behavior.
Controller compatibility with Node Agent versions `N` and `N-1` does not itself prove that concurrent processes can safely share one Node Identity Root.

## Decision

The current native macOS distribution is the signed and notarized DMG containing `Orchard.app`.
`Orchard.app` retains its root-authorized role-aware service lifecycle, transactional rollback, retained-state, signing, and DMG verification obligations.
Source-development workflows and supported public, operator, admin, and Runtime Endpoint APIs are unchanged.

Native PKG is removed from the active distribution contract.
Native PKG scripts, package assets, dedicated tests, and active operator documentation are removed.
The app retains legacy PKG receipt detection only to prevent silent ownership takeover of an existing installation, not as a supported artifact, operator workflow, release gate, or product promise.

ADR 0018's Managed Node Agent Handover, zero-process-overlap, shared lifecycle exclusion boundary, durable start-eligibility state, one-shot launch authorization, provisional child acceptance, PKG inert staging, and associated recovery protocol are removed from the current contract.
Orchard does not replace them with a weaker implicit handover guarantee.
Sequential node upgrades continue to use cordon, drain, the app-owned update lifecycle, version and health verification, and uncordon.
The `N` and `N-1` compatibility rule remains a wire and behavior compatibility obligation across that rolling sequence, not authorization for concurrent use of one Node Identity Root.

Any future native package, additional distribution channel, or managed Node Agent replacement protocol requires a fresh OpenSpec proposal and a separate implementing pull request.
That work must update `SPEC.md`, decisions, active specs, security posture, operator documentation, and validation gates before support is claimed.
Legacy PKG material and this superseded handover design are historical input only and cannot serve as approval.

## Consequences

The active product contract matches the supported Orchard.app/DMG path instead of promising an unimplemented PKG and handover design.
Release and contributor guidance no longer directs users to build, install, validate, or operate a native PKG.
The app-owned lifecycle continues to preserve operator state and fail closed when rollback cannot be completed or verified.
Orchard makes no current zero-overlap managed Node Agent replacement guarantee.
A later packaging or handover design starts from current product needs and must earn explicit review rather than inheriting authority from dormant files.

## SPEC.md impact

Update §§1.4, 2.4-2.5, 11, 13.3-13.4, and the implementation roadmap to remove native PKG and ADR 0018 handover requirements while preserving Orchard.app, DMG, source development, APIs, rolling-version compatibility, and app lifecycle safety.
