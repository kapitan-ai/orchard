# ADR: Activate managed macOS Node compositions with retained identity and zero process overlap

## Status

Proposed under the `managed-macos-node-composition-provenance` OpenSpec change.

## Context

The supported macOS native distribution profile currently uses a signed `Orchard.app` inside a DMG and deliberately has no managed source-to-package handover contract.
ADR 0027 removed native PKG and its incomplete handover machinery because it could not prove one verified custody chain or zero process overlap.
The current app lifecycle journal can restore services automatically during rollback and recovery, while the source-development Node Agent stop path proves exact process custody only for one foreground development lifecycle.
Neither mechanism is sufficient for an in-place provenance transition of a managed Node that must remain unschedulable whenever verification, rollback, or process custody is uncertain.

## Decision

Introduce one role-specific Managed Apple Silicon macOS Node Distribution Profile under the existing macOS native distribution profile.
The profile admits exactly two composition realizations: `exact_ref_source_build` and `orchard_signed_prebuilt`.

Both realizations produce the same closed component contract consisting of a macOS arm64 Node Agent component built from the provider-neutral Node Agent core, a launchd host adapter, and an exact-pinned MLX Worker Provider.
Closed component manifests feed a composition lock.
A detached build attestation binds the realization, builder policy, controlled inputs, and resulting composition-lock digest without referencing itself or later release metadata.

One verifier returns the same decision shape for both realizations.
Realization-specific validators remain distinct because exact-ref source trust and Orchard signing trust are not interchangeable.
An arbitrary clean Git commit is a custom local build unless it satisfies the configured canonical-repository, authorized-ref, controlled-builder, and pinned-input policy.

Activation is coordinated with the Controller.
The Node enters maintenance, drains allocations, and receives Controller acknowledgement before host mutation begins.
The host then acquires the operation lock, establishes durable launch suppression, records a versioned activation journal, captures the exact outgoing managed process set, stops it, proves exit and no replacement, activates and re-verifies the new bytes, and commits an `activated_stopped` state.
Starting the new composition is a separate verified phase.
The Controller may uncordon the Node only after the new process reports the expected composition identity and passes health and compatibility checks.

One privileged host helper and versioned helper protocol own the supported managed launch-domain process fence.
The zero-overlap guarantee covers every managed process that can be started through that launch domain.
The v1 profile does not claim to fence arbitrary manually started or externally supervised processes.

The activation journal separates byte restoration from service restoration.
Recovery and rollback restore only a verified compatible composition and leave it stopped until an explicit start succeeds.
Older lifecycle code must reject the managed-composition journal schema rather than infer recovery behavior.
Any uncertain verification, compatibility, journal, rollback, or custody result leaves the Node launch-suppressed, stopped, and in Controller maintenance.

The Node Identity Root is outside the replaceable composition tree and is retained across both realization directions.
Each composition declares readable and writable identity-schema ranges.
The v1 transition set prohibits irreversible identity-schema mutations that would prevent restart of either supported transition endpoint.

The verified composition is an input to `Orchard.app` assembly.
The app tree identity is then recorded by the Candidate or Internal Build Manifest and wrapped by the signed DMG according to the existing distribution contract.
Neither a component archive nor a composition lock is independently a supported distribution artifact.

Foreground source development remains governed by `make dev` and existing source-development lifecycle commands.
It does not silently become a managed composition or participate in managed activation.

## Consequences

The profile can prove source-built to prebuilt and prebuilt to source-built provenance transitions through one custody chain without reviving native PKG handover.
Activation causes downtime and requires Controller coordination, but a failed or ambiguous transition cannot return a Node to scheduling accidentally.
Build and release identities remain acyclic, and release governance can incorporate composition evidence without allowing component metadata to claim publication authority.
The implementation must replace or extend current automatic service-restoration behavior for this journal schema and centralize process-fence logic behind one helper protocol.
Real Apple Silicon migration qualification is required before the profile is described as supported.

## Alternatives Rejected

Reviving native PKG handover was rejected because native PKG is not a supported current distribution channel and ADR 0027's removal remains valid.
Treating a Node Agent archive as the supported product was rejected because it bypasses the app, DMG, signing, lifecycle, and release-governance contracts.
Using different activation paths for source-built and prebuilt realizations was rejected because it would duplicate safety logic and permit provenance class to alter custody semantics.
Automatically restarting a restored composition during rollback was rejected because restored bytes do not prove compatibility, custody, or Controller eligibility.
Claiming zero downtime was rejected because the smallest safe slice requires a stopped interval to prove no process overlap.
A lifetime identity lease for arbitrary process launch paths was deferred because v1 can make a precise guarantee over one supported managed launch domain without broadening the host-security model.

## SPEC.md Impact

Acceptance requires a focused amendment to §§1.4, 2.5, 4.1, 4.9, 4.10, 11.3, 11.4, and 13.4.
That amendment narrowly supersedes ADR 0027's no-managed-handover conclusion only for the named profile and two admitted realizations.
All native PKG removal, other profile boundaries, foreground source-development behavior, and explicit release and credential gates remain unchanged.
This ADR does not itself change `SPEC.md` or product behavior.
