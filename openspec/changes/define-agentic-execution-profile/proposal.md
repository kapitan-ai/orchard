## Why

Orchard already defines client-executed tool passthrough, typed Responses tool events, exact reasoning negotiation, retries, cancellation, capacity release, cache affinity, and model qualification. It does not yet define one provider- and agent-client-neutral profile that composes those contracts into reproducible agent-loop acceptance evidence without confusing protocol correctness, one exact workload qualification, and production activation.

## What Changes

- Define an Agentic Execution Profile with separate protocol-conformance, exact-tuple workload-qualification, and production-activation boundaries.
- Make a deterministic reusable corpus the first implementation deliverable before any real-model or hardware qualification.
- Define measurable pass/fail gates for typed final text, reasoning, tool-call continuation, structured output, schemas, usage, terminals, cancellation and native drain, cache identity and affinity, and retry/error behavior.
- Name OpenCode only as the first conformance client, bound to its exact version and configuration.
- Preserve client ownership of the agent loop, tool authorization, argument validation, execution, continuation, and loop limits.

## Capabilities

### New Capabilities

- `agentic-execution-profile`: Defines neutral conformance, exact qualification, and activation evidence for client-owned agent loops.

### Modified Capabilities

None. Existing API, runtime, retry, cancellation, capacity, cache, and qualification contracts remain authoritative for their behavior.

## Impact

- `SPEC.md` adds the profile kind and its composed acceptance contract.
- The change adds no runtime code, public fields, protocol encoding, model allowlist, production configuration, or support claim.
- `parallel_tool_calls=true` remains unsupported.
- Qwen3.8 remains unactivated and unclaimed.
- TensorFold is not adopted as a runtime foundation.
