## Context

`SPEC.md` §7.3.4 makes retry an operator-only, source-evidence-dependent new Request. The existing request row has `retry_of_request_id`, the canonical serializer preserves legacy omission behavior, and `CapturePolicy` provides the capture lattice. No existing endpoint atomically reserves descendants or re-enters a durable request through normal dispatch.

The unmerged #327 negotiated reasoning work is not available on this base. A stored `reasoning` entry therefore cannot prove a complete effective identity or compatible Runtime Endpoint. This slice must treat it as unavailable rather than infer a mode, remove the entry, or renegotiate.

## Design

The retry service runs one database transaction that locks the source Request, locks its original Request (the source itself for first-generation retry), locks the source tenant for its current capture policy, validates the source and its legacy canonical serialization, counts existing descendants, and inserts the new descendant only when the count is below three. Locking the original serializes concurrent retry reservations for one lineage.

Retry re-enters admission at the point where a Request row is created, so the
reservation transaction re-resolves the authorization inputs that the public
path resolves in `Orchard.Inference.RequestPreparation`: the source Model must
still be `active`, and the source Tenant must still hold an enabled Model access
grant. A revoked grant, a disabled grant, or a non-active Model returns
`retry_source_not_authorized` before a descendant exists, so a retry cannot
dispatch inference or account usage for a Tenant that is no longer authorized.
The descendant's resolved policy comes from that current grant rather than the
retained snapshot, and a retained queue-wait or cold-start budget is narrowed to
the current grant's budget instead of being widened by it. The retained
generation budget is preserved and remains subject to the deployment deadline
ceiling.

One request-attrs builder on `Orchard.Inference.RequestOrchestrator` serves both
the public persistence path and retry, so the pre-persistence admission
fail-safe, the persistable-deadline check, canonical serialization rescue, the
deadline ceiling, and reserved-output defaults cannot drift between them.

The service accepts only the `failed`, `cancelled`, `timed_out`, and `interrupted` source states. It accepts only `payload_capture_mode: :full` with a complete canonical map whose stored endpoint, tenant, principal, credential, model reference, and public identifier agree with the durable source row. It decodes only the fixed legacy serialization vocabulary and preserves legacy omitted-reasoning behavior. Missing or malformed retained evidence returns `retry_source_unavailable` and rolls back the transaction.

The service rejects every retained `reasoning` key before it creates a descendant. This is the dependency-safe #327 gate: it neither fabricates nor drops negotiated identity and dispatches nothing on that path.

The descendant receives a fresh canonical and public identifier, its `retry_of_request_id` points to the original Request, and it has no idempotency key. Its canonical body hash is calculated from the exact legacy serializer output. Its capture mode is the lattice minimum of the retained source and the currently locked tenant policy, followed by ordinary `store` resolution; existing persistence sanitizes content for `metadata` and `none`.

After the transaction commits, the retry service hands the already-persisted descendant to the existing request lifecycle and scheduler seam. It does not parse a public request, reserve a new idempotency key, or introduce automatic retry behavior.

A dispatch that reaches a durable terminal outcome is reported as a created
descendant carrying that state. When the orchestrator cannot write the terminal
row, the descendant is retained for audit and recovery, a bounded log records
only the descendant public identifier, its original Request identifier, and an
outcome label, and the caller receives `retry_dispatch_incomplete` instead of a
success response.

## Failure Handling

- Missing source: `request_not_found`.
- Non-terminal or unsupported source state: `retry_source_not_eligible`.
- Missing, non-full, malformed, identity-inconsistent, or negotiated retained canonical source: `retry_source_unavailable` with no descendant and no dispatch. Malformed includes a non-map nested section, a non-positive retained `timeout_ms`, a canonical serialization that cannot be produced, and a descendant insert the database rejects.
- Non-active Model or revoked/disabled Tenant Model access: `retry_source_not_authorized` with no descendant and no dispatch.
- Created descendant whose terminal outcome cannot be persisted: `retry_dispatch_incomplete`, with the descendant retained.
- Three existing descendants for the original: `operator_retry_limit_reached` with no new row.
- Existing control-plane write authorization remains before reservation and dispatch.

## #327-Gated Follow-Up

Once #327 and its prerequisite canonical reasoning work are merged and accepted, add a separate negotiated branch that reconstructs and verifies the complete stored effective reasoning tuple and proves compatible Runtime Endpoint capability before the existing reservation and dispatch path. Until then, retain the fail-closed `retry_source_unavailable` branch.
