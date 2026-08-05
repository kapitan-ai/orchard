## 1. Contract

- [x] 1.1 Add the narrow active OpenSpec proposal, design, and runtime-endpoint/scheduler deltas
- [x] 1.2 Synchronize the accepted contract into `SPEC.md` §§5.5, 5.9, 6.8, and 7.5.2
- [x] 1.3 Validate the change strictly and run strict validation for all OpenSpec material

## 2. Runtime Endpoint evidence

- [x] 2.1 Add optional field 7 using `RuntimeModelPlacement` to `EnsureModelLoadedResponse` and regenerate protobuf output
- [x] 2.2 Add optional canonical Placement Capacity to the Runtime Endpoint load result with version-skew-safe consumption
- [x] 2.3 Normalize valid matching evidence with status-equivalent rules and map absent or invalid evidence to missing
- [x] 2.4 Produce evidence for successful cold and already-loaded replies without an additional Controller status operation

## 3. Compatibility revalidation

- [x] 3.1 Thread the successful load result to arity-one final revalidation providers while preserving arity-zero providers
- [x] 3.2 Consume valid matching evidence for initially cold compatibility candidates without replacing captured identity
- [x] 3.3 Preserve captured valid matching capacity for initially loaded candidates when the additive field is absent
- [x] 3.4 Fail closed on absent, malformed, or model-mismatched cold-load evidence without another status attempt

## 4. Verification

- [x] 4.1 Cover valid cold and already-loaded evidence, invalid evidence, and worker-status failure
- [x] 4.2 Cover old protobuf and BEAM result shapes, wrong-model evidence, and both explicit unmanaged classifications
- [x] 4.3 Prove one compatibility status attempt through execution, fail-closed handling, and terminal completion
- [x] 4.4 Run the applicable AGENTS.md Elixir quality and coverage workflow
