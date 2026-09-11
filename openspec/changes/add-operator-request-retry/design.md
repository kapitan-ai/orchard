## Context

`SPEC.md` §7.3.4 makes retry an operator-only, source-evidence-dependent new Request. The existing request row has `retry_of_request_id`, the canonical serializer preserves legacy omission behavior, and `CapturePolicy` provides the capture lattice. No existing endpoint atomically reserves descendants or re-enters a durable request through normal dispatch.

The unmerged #327 negotiated reasoning work is not available on this base. A stored `reasoning` entry therefore cannot prove a complete effective identity or compatible Runtime Endpoint. This slice must treat it as unavailable rather than infer a mode, remove the entry, or renegotiate.

## Design

The retry service runs one database transaction that locks the source Request, locks its original Request (the source itself for first-generation retry), locks the source tenant for its current capture policy, validates the source and its legacy canonical serialization, counts existing descendants, and inserts the new descendant only when the count is below three. Locking the original serializes concurrent retry reservations for one lineage.

The service accepts only the `failed`, `cancelled`, `timed_out`, and `interrupted` source states. It accepts only `payload_capture_mode: :full` with a complete canonical map whose stored endpoint, tenant, principal, credential, model reference, and public identifier agree with the durable source row. It decodes only the fixed legacy serialization vocabulary and preserves legacy omitted-reasoning behavior. Missing or malformed retained evidence returns `retry_source_unavailable` and rolls back the transaction.

The service rejects every retained `reasoning` key before it creates a descendant. This is the dependency-safe #327 gate: it neither fabricates nor drops negotiated identity and dispatches nothing on that path.

The descendant receives a fresh canonical and public identifier, its `retry_of_request_id` points to the original Request, and it has no idempotency key. Its canonical body hash is calculated from the exact legacy serializer output. Its capture mode is the lattice minimum of the retained source and the currently locked tenant policy, followed by ordinary `store` resolution; existing persistence sanitizes content for `metadata` and `none`.

After the transaction commits, the retry service hands the already-persisted descendant to the existing request lifecycle and scheduler seam. It does not parse a public request, reserve a new idempotency key, or introduce automatic retry behavior.

## Failure Handling

- Missing source: `request_not_found`.
- Non-terminal or unsupported source state: `retry_source_not_eligible`.
- Missing, non-full, malformed, identity-inconsistent, or negotiated retained canonical source: `retry_source_unavailable` with no descendant and no dispatch.
- Three existing descendants for the original: `operator_retry_limit_reached` with no new row.
- Existing control-plane write authorization remains before reservation and dispatch.

## #327-Gated Follow-Up

Once #327 and its prerequisite canonical reasoning work are merged and accepted, add a separate negotiated branch that reconstructs and verifies the complete stored effective reasoning tuple and proves compatible Runtime Endpoint capability before the existing reservation and dispatch path. Until then, retain the fail-closed `retry_source_unavailable` branch.
