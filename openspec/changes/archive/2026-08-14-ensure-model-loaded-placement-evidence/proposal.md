# Add post-load placement evidence for compatibility revalidation

## Why

A cold explicitly unmanaged compatibility candidate is observed before its requested Model
Placement exists. After `EnsureModelLoaded` succeeds, final dispatch revalidation requires
Node-owned Placement Capacity, but the captured status observation cannot contain that
new placement and Orchard permits only one compatibility status attempt per target for the
logical request. Reusing unknown capacity would fail valid cold loads, while assuming
capacity or probing status again would violate `SPEC.md` §§5.5 and 5.9 and ADRs 0013 and
0017.

## What changes

- Add optional matching Placement Capacity evidence to successful
  `EnsureModelLoaded` results.
- Let explicitly unmanaged compatibility final revalidation consume that additive evidence
  for an initially cold placement while retaining captured target and Node identity.
- Fail closed before `ExecuteInference` when post-load evidence is absent, malformed, or
  names a different model.
- Preserve an initially loaded compatibility candidate's captured valid matching Placement
  Capacity when an additive load-result field is absent.
- Define additive protocol and BEAM version-skew behavior without a second compatibility
  status attempt.

## Out of scope

- Production snapshot candidate construction or durable observation behavior.
- Controller-owned dispatch-capacity policy, allocation, or acceptance-gate changes.
- A second status probe, status retry, or broader compatibility-wave change.
- Public error-policy changes.
- Implementation in this documentation-only plan item.

## SPEC.md impact

This change updates `SPEC.md` §§5.5, 5.9, 6.8, and 7.5.2. It makes successful
`EnsureModelLoaded` Placement Capacity additive and optional for version compatibility,
requires valid matching evidence for an initially cold compatibility candidate's final
revalidation, preserves captured capacity for an initially loaded candidate, and keeps the
one-status-attempt invariant.
