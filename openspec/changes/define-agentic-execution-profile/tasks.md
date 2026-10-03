# Tasks

## 1. Contract

- [x] 1.1 Reconcile the profile with `SPEC.md`, `normalize-responses-tool-calling`, `qualify-mlx-tool-calling`, capability admission, model qualification, reasoning, retry, cancellation/drain, capacity, and cache-affinity contracts, including profile-level native-drain evidence, scoped terminal/usage assertions, bounded fingerprint identity, and endpoint/mode applicability.
- [x] 1.2 Define the neutral profile, exact immutable qualification identity, activation boundary, and measurable gates without runtime implementation or support claims.
- [ ] 1.3 Obtain collaborator review and accept this contract before implementation.

## 2. Deterministic reusable corpus

- [ ] 2.1 Define a versioned corpus format for request inputs, scripted provider-neutral events, expected public events, terminal outcomes, usage, client decisions, and tool side effects.
- [ ] 2.2 Implement the scripted provider-neutral fixture and corpus runner before any hardware qualification.
- [ ] 2.3 Add applicable positive, negative, and dependency-blocked cases for typed final text, reasoning, tool calls and continuation, structured output, caller/generated schema handling, attempt-scoped usage, scoped terminal outcomes, disconnect cancellation and proven native drain, bounded cache identity/affinity, retry/errors, and `parallel_tool_calls=true` rejection.
- [ ] 2.4 Produce a sanitized machine-readable result that identifies corpus version, Orchard revision, endpoint/mode, client adapter identity, and every pass/fail assertion without prompts, generated content, credentials, local paths, or tool/session identifiers.

## 3. First conformance client

- [ ] 3.1 Adapt one exact OpenCode version and configuration to the corpus without adding client-specific semantics to the profile.
- [ ] 3.2 Prove OpenCode owns loop control, schema validation, tool authorization/execution, continuation, and loop limits while Orchard executes no client tool.
- [ ] 3.3 Record failures as bounded conformance findings for that exact client identity; do not claim general OpenCode or other-client support.

## 4. Exact-tuple qualification

- [ ] 4.1 Select an exact model/runtime/client tuple only after the deterministic corpus passes and record every immutable identity field required by `SPEC.md` §7.2.9 and repository model-qualification governance.
- [ ] 4.2 Run the corpus and semantic workload on applicable real hardware, including provider-native cancellation/drain and failure injection.
- [ ] 4.3 Review qualification independently from activation; do not activate Qwen3.8 or infer family/runtime/client support from the result.

## 5. Activation and validation

- [ ] 5.1 Require an approved qualification record, active scoped support claim, applicable profile gates, and explicit operator decision before production activation.
- [x] 5.2 Run strict OpenSpec validation for this contract package.
- [ ] 5.3 After archive or sync, inspect generated main specs for placeholder prose and validate all OpenSpec packages strictly.
