## Why

Orchard can build and verify a signed macOS app and can stop a source-development Node Agent with exact process custody, but it does not have one supported contract for changing the provenance of a managed Apple Silicon macOS Node in place.
The smallest safe slice must make a source-built and an Orchard-signed prebuilt realization converge on the same closed composition identity, verification decision, Controller maintenance state, host process fence, activation journal, rollback policy, and retained Node Identity Root before any behavior implementation begins.

## What Changes

- Define one role-specific Managed Apple Silicon macOS Node Distribution Profile under the existing macOS native distribution profile.
- Define exactly two admitted composition realizations: `exact_ref_source_build` and `orchard_signed_prebuilt`.
- Compose a macOS arm64 Node Agent component built from the provider-neutral Node Agent core, a launchd host adapter, and an exact-pinned MLX Worker Provider.
- Require closed component manifests, a composition lock, and a detached build attestation with an acyclic identity graph.
- Require both realizations to pass one verifier decision contract while preserving realization-specific trust gates.
- Require Controller maintenance and drain acknowledgement before host activation and explicit Controller uncordon after the new composition is healthy.
- Define one process-fence authority for the supported managed launch domain, with durable launch suppression, exact outgoing-process capture, zero-overlap proof, and replacement-process rejection.
- Replace implicit service restoration with a versioned activation journal and separate activation from start.
- Retain the Node Identity Root outside replaceable composition bytes and make schema compatibility a precondition for activation, rollback, and restart.
- Require uncertain activation, rollback, custody, or compatibility outcomes to remain stopped, launch-suppressed, and unschedulable.
- Define how a verified managed Node composition is incorporated into `Orchard.app`, the Candidate or Internal Build Manifest, and the DMG without making a component archive an independently supported distribution.
- Require public-interface acceptance and migration evidence for `exact_ref_source_build` to `orchard_signed_prebuilt` and the reverse realization transition with no managed-process overlap.
- Preserve foreground `make dev` and the existing source-development lifecycle.
- Keep Amore publication, release credentials, Linux, WSL, Windows, relaxed version skew, zero-downtime activation, native PKG, and removed-PKG handover outside this change.

## Capabilities

### New Capabilities

- `managed-node-composition`: Defines the closed managed Node composition, provenance realizations, identity graph, trust policy, common verifier decision, retained Node Identity Root, and evidence-bound support claim.

### Modified Capabilities

- `platform-profiles`: Adds the role-specific Managed Apple Silicon macOS Node Distribution Profile and its narrow admission boundary.
- `packaging-deployment`: Defines composition derivation into `Orchard.app` and the DMG while preserving the app and DMG as the supported outer artifacts.
- `app-distribution-lifecycle`: Defines fail-closed, journaled, two-phase composition activation, start, recovery, and rollback.
- `host-lifecycle-adapters`: Defines the single managed-launch-domain process fence and durable launch suppression contract.
- `operator-command-authority`: Defines coordinated Controller maintenance, drain, activation, health, and uncordon authority.
- `portability-validation`: Adds public-seam and real Apple Silicon transition proof for both provenance directions and failure states.

## Impact

- SPEC.md impact: acceptance would refine §§1.4, 2.5, 4.1, 4.9, 4.10, 11.3, 11.4, and 13.4 to add one managed Apple Silicon macOS Node profile, closed composition provenance, coordinated maintenance, zero-overlap activation, retained identity, and fail-closed rollback.
- SPEC.md conflict resolution: the accepted implementation would narrowly supersede the no-managed-handover statement in §11.4 and ADR 0027 only for this named profile and these two realizations.
- SPEC.md preservation: native PKG remains removed, ordinary source development remains foreground and unmanaged, the current app and DMG distribution profile remains the supported outer artifact, and other platform profiles gain no new support claim.
- Decision impact: add ADR 0030 to record the narrow managed-composition exception, two-phase activation model, process-fence authority, and retained identity rule.
- Release-governance dependency: the composition lock and detached build attestation are inputs to, not substitutes for, the Candidate or Internal Build Manifest owned by `product-versioning-release-governance`.
- Runtime compatibility dependency: each composition records the Runtime Endpoint compatibility epoch and required compatibility assets without accelerating the staged removal proposed by `deprecate-node-runtime-grpc-compatibility`.
- Packaging impact: the existing app and DMG build paths would gain closed composition inputs and verification gates, but no publication or credential use is authorized by this change.
- Controller impact: activation becomes a coordinated maintenance operation rather than a host-local service restart.
- Host impact: the current lifecycle journal and auto-restart recovery behavior cannot govern a managed composition transition and must fail closed when encountering the new journal schema.
- Identity impact: the Node Identity Root remains durable across composition replacement, while irreversible identity-schema mutations are prohibited within the v1 transition set.
- Validation impact: both realization directions require public-interface transition tests and real Apple Silicon migration evidence before the profile can be claimed as supported.
- Implementation impact: this package defines intent and acceptance only and makes no runtime, packaging, signing, publication, or release change.
