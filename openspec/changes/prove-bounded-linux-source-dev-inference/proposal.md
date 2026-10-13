## Why

Historical KAP-112 explored a thin vLLM Worker route, but its final-only runtime
registration and proof claims cannot be replayed onto main's KAP-49 contract.
This package rewrites durable intent from `31ed46b5` and `b66a4001` as an
independent default-off implementation experiment, not fulfillment of the
accepted `reconcile-linux-node-source-dev-contract` change.

## What Changes

- Permit separately selected `vllm_poc` behind existing local gRPC and loopback
  HTTP `/v1/completions` on 58080, with logical load/unload and concurrency one.
- Preserve rendered prompts and legacy-blended generated reasoning; use stateful
  framing only to locate the final suffix for fail-closed Qwen XML tool parsing.
- Require pinned sampling and bounded total decoded output, reject token IDs and
  logprobs, and use UUID tool-call IDs under KAP-116.
- Keep historical setup and live runner disabled; retain deterministic evidence
  only. No new Controller/shared/tokenizer registration or public final-only
  contract is introduced.

## Capabilities

### New Capabilities

- `linux-source-dev-inference-poc`: bounded Worker experiment and execution gates.

### Modified Capabilities

None. Platform qualification contracts remain unchanged.

## Impact

`SPEC.md` §7.2.9 gains only the permission quoted in ADR 0037. `SPEC.md` §1.4,
§1.5, §4.10, M9 and ADR 0035 remain authoritative and unchanged. This proposal
grants no live execution, native cessation, custody, capacity, model/provider/
platform qualification or support. Historical acceptance does not accept this
revision; no current-main real API/OpenCode proof is claimed.
