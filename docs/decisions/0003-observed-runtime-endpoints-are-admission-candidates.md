# Observed Runtime Endpoints are admission candidates

Accepted.

First-observed Runtime Endpoint metadata is not Node trust, Node registration, or scheduling authority.
Orchard will treat an unreconciled first observation as a Runtime Endpoint Admission Candidate outside the Node Lifecycle State machine until an admin-created placeholder, `RegisterNode`, or equivalent trust proof reconciles it to a managed Node.
This preserves the distinction between live runtime observation and durable cluster membership, prevents accidental cluster expansion, and keeps queue capacity and scheduler eligibility tied to trusted active Nodes.

Rejected node admission is persisted as a Node Admission Decision, not as `decommissioning`.
Re-admission after rejection requires current trusted registration state plus either an explicit admin clear action or a new registration and trust event recorded in audit.
The trade-off is an extra admission-candidate persistence path before implementation can simplify observed nodes into inventory rows, but the boundary is hard to reverse once operators and support bundles rely on it.

## Platform portability scope

ADR 0023 removes the definition of a Node as only an Apple Silicon macOS machine, but it does not weaken this admission boundary.
An observation from any platform or runtime provider remains untrusted candidate evidence until it reconciles to durable Node identity, trust, admission, lifecycle, capability, and policy state.
Platform, provider, device, or transport metadata MUST NOT make an observed endpoint schedulable by itself.

## Support-bundle retirement

Partially superseded 2026-09-02: support bundles were retired before beta.
The Runtime Endpoint admission boundary remains authoritative, but support bundles are no longer a consumer or delivery target.
