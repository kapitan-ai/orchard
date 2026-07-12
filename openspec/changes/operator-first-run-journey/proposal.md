## Why

Orchard now has an app-primary DMG, a safe root-authorized service lifecycle, first-admin credential initialization, admission review, and a secure enrollment tracer through certificate-backed gRPC compatibility activation.
The operator still has to assemble those capabilities through external Postgres preparation, root-owned env edits, shared BEAM cookie distribution, explicit Runtime Endpoint targets, separate trust and Console steps, per-worker model staging, and manual inference verification.

The current path and target `SPEC.md` path are spread across packaging, local-development, security, node-lifecycle, model, and Console documents.
Without one durable journey and ordered change package, current behavior can be mistaken for finished Node Enrollment or model distribution, and future setup work can encode temporary transport mechanics into the product experience.

## What Changes

- Add a durable operator-journey document that separates current supported behavior, target product intent, and the ordered gap map.
- Define controller-only, all-in-one, and Controller-plus-worker differences from release acquisition through Console and first inference.
- Make sudo/root authorization, external Postgres, licensing, public transport, first-admin credentials, current BEAM transport, Node Admission, model availability, retained state, recovery, and upgrade responsibilities explicit.
- Define structural friction counts and stable measurement boundaries for time-to-Console, time-to-first-worker-ready, and time-to-first-inference.
- Define **Node Enrollment Bundle** as the canonical per-Node bootstrap artifact and prohibit shared BEAM cookies or long-lived credentials from that artifact.
- Preserve the CLI-first secure one-Controller, one-Node enrollment tracer as the completed Section 2 identity foundation.
- Record that the secure enrollment tracer shipped in PR #87 while its root-owned packaged, restart, separate-release, and two-Mac acceptance remains open.
- Select OTP TLS distribution plus an exact Controller-to-Node BEAM Peer Grant as the enrolled production identity and authorization model.
- Define per-Controller authorization roots, hash-only Postgres state, certificate-authenticated grant delivery, inventory-derived names and targets, rotation, revocation, Active/Standby isolation, visible failures, and the high-trust BEAM boundary.
- Shape a narrow one-Controller, one-Node BEAM Peer Grant tracer as the first Section 3 implementation slice without implementing it here.
- Preserve enrollment lifecycle hardening, controller-hosted model distribution, Playground verification, app-guided setup, Managed Database Mode, and coordinated upgrade work as explicit later tasks.
- Reconcile the narrow `SPEC.md` contradiction between credential-only `orchardctl cluster init` and internal Controller CA initialization.

## Capabilities

### New Capabilities

- `operator-first-run-journey`: Defines current-versus-target operator journey disclosure, secure Node Enrollment, measurable setup outcomes, recovery semantics, first-inference completion, and phased implementation acceptance.

### Modified Capabilities

- None.

## Impact

- Documentation impact: add `docs/operator-journey.md`, link it from the docs index, and add the Node Enrollment Bundle glossary term.
- SPEC.md impact: reconcile §3.3, §4.1, §7.5, §8, and §10.6 for durable Controller identity, production BEAM Peer Grants, their normative persistence model, and node trust initialized separately from credential-only `orchardctl cluster init`.
- OpenSpec impact: add this shaping package without modifying or claiming completion of `cluster-management-ux-foundation`, `first-admin-cluster-init`, or `amore-dmg-service-lifecycle`.
- Security impact: establish that Node Enrollment cannot package the cluster-wide BEAM cookie, admin credentials, CA private keys, Node private keys, or long-lived Node Certificates, and that production BEAM requires exact certificate validation plus a scoped Peer Grant.
- Implementation impact: none in this change.
- Completed implementation: PR #87 delivered Node Enrollment persistence, one-time output, local key generation, certificate-backed registration, explicit Node Admission, dynamic target resolution, and certificate-backed gRPC authenticated activation; root-owned packaged, restart, separate-release, and two-Mac acceptance remains open.
- Future implementation impact: the next product-code slice is the narrow Section 3 BEAM Peer Grant tracer.

## Non-Goals

- Do not implement product code, new CLI commands, database migrations, app UI, Node Certificate issuance, model transfer, or upgrade orchestration in this change.
- Do not claim dynamic multi-Node production target discovery, controller-hosted model distribution, Managed Database Mode, or app-guided setup exists.
- Do not replace the current packaged BEAM first-cut runbook before the secure product path is implemented and validated.
- Do not implement Section 3 product code, persistence, CLI surfaces, TLS distribution configuration, Peer Grant delivery, rotation, revocation, or Active/Standby behavior in this contract change.
- Do not mirror the complete operator journey into `SPEC.md`.
