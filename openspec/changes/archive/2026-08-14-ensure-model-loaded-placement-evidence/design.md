# Design: load-result placement evidence without a second status attempt

## Decision source

`SPEC.md` §5.5 and ADR 0017 bound explicitly unmanaged compatibility observation to one
status attempt per target. `SPEC.md` §5.9 and ADR 0013 require valid Node-owned Placement
Capacity at final revalidation. The load operation is the only existing operation between a
cold observation and final revalidation that can return the newly created placement's
current Node-owned capacity.

## Additive evidence contract

A successful `EnsureModelLoaded` result may carry Placement Capacity for the exact
requested model reference. Valid evidence contains a non-negative active request count and
a positive maximum concurrency. The Node Agent derives it from the same serialized
model-manager state and trustworthy worker-status result already used to construct the
successful load response; it does not make another Controller-visible status call.

The gRPC Compatibility Adapter adds optional field 7 to
`EnsureModelLoadedResponse`, using the existing `RuntimeModelPlacement` message. Runtime
Endpoint domain results expose the normalized optional Placement Capacity. Absent,
malformed, zero-maximum, negative, or invalid-model-reference evidence normalizes to
missing rather than fabricated capacity. Failed or non-loaded results do not supply
placement authority.

## Compatibility final revalidation

Acquisition continues to use the captured compatibility observation. A cold candidate may
treat placement capacity as not applicable before loading. After a successful load, final
revalidation preserves the captured target, resolved Node identity, aggregate capacity,
availability, health, observation time, freshness behavior, and explicit unmanaged
classification. It replaces only the initially absent placement fact with valid matching
load-result evidence.

Missing, malformed, or model-mismatched load-result evidence fails final revalidation
before `ExecuteInference`. The load result does not replace captured identity proof. An
initially loaded candidate keeps its captured valid matching Placement Capacity when the
additive result field is absent; valid newer matching evidence may replace it.

## Provider compatibility

Only the default inline-status compatibility final provider consumes the successful load
result. Production snapshot providers, SingleNode providers, and existing injected
providers may remain zero-arity. Dispatch invokes an arity-one provider with the successful
load result and retains arity-zero invocation compatibility.

## Version skew

- New Controller with old protobuf or BEAM agent: the optional field/key is absent. An
  initially cold compatibility request fails closed after load and does not execute or
  issue another status attempt.
- Old Controller with new protobuf agent: the unknown protobuf field is ignored.
- New Controller with an old same-named BEAM result struct: consumers use optional-key
  lookup rather than direct field access, so the absent key becomes missing evidence
  instead of raising.

## Status-attempt invariant

The initial compatibility wave remains the only Controller Runtime Endpoint status
operation. Loading, provider invocation, final revalidation, failure handling, retry/queue
handling, and terminal completion must not add a connect/status attempt for the same
logical request. Internal worker-status reuse while constructing a load response is not a
Controller Runtime Endpoint status attempt.

## Failure and public behavior

Invalid post-load evidence uses the existing final capacity-revalidation failure path and
existing queue/retry/public error contract. No new public error code or durable state is
introduced.
