## Rendering

The assessed Qwen template is unchanged. Transformers and Orchard use different JSON serialization filters for the template's tool definitions. The isolated provider must use the authoritative Orchard sandbox through MLX-LM's existing custom-template callable seam, rather than silently accepting different IDs. Both prompt and no-generation-suffix history use the same verified template and options. The callable is local child configuration, never caller authority.

## Admission and custody

The implementation will use the existing ExecuteInferenceRequest, effort profiles and Node-owned Worker process boundary. A versioned trusted projection is optional for baseline Workers and mandatory only for the explicitly selected bridge. An old Worker accepting an unknown protobuf field does not demonstrate bridge capability. HTTP terminal events and health cannot release residency. Any uncertainty blocks admission until settlement or positive reaping.

## Gates

The source copy-custody primitive reserves declared conservative copy and transient
bounds before invoking the provider, alongside frozen workspace and held leases.
Staged, retained and borrowed owners share one reservation until explicit settled
disposal. Only one copy may be in flight; uncertain copy or settlement quarantines
the incarnation. A returning result remains strongly held even while a concurrent
reap attempt fails. Positive owned reaping retires the ledger permanently.

This primitive is not yet an installed engine hook or a complete state envelope.
Known cache sizing, working-KV growth, producer buffers, native settlement and
Node-owned process-tree confirmation require separate integration and tests.

The source token buffer bounds queued chunk count, total token count, individual
chunk size and the admitted vocabulary. Immutable queued chunks prevent caller
mutation from changing those bounds. Terminal capacity is independent of data
capacity, while invalid input or overflow permanently fails the buffer and invokes
quarantine outside its lock. This does not bound downstream accumulated output or
prove native settlement. The upstream scheduler does not catch producer-put faults
as a normal completed request; the bridge must treat them as incarnation faults.

Provider reasoning/content splitting is lossy: closing markers and following
newlines may be removed before HTTP deltas are emitted. Concatenating those fields
cannot establish Orchard's existing legacy-blended output preservation. The isolated
child needs an internal raw-generation seam or equivalent exact preservation proof;
it must not enable a new public structured-reasoning contract as a shortcut.

Tokenizer-only parity does not qualify a live HTTP child, checkpoint memory fit or native drain. No protocol fields or dispatch route will be added before saved natural-history parity and bounded state feasibility succeed. Source implementation and model-free tests do not authorize a hardware run.
