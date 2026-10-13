## Why

Historical KAP-112 explored a thin vLLM Worker route, but its final-only runtime
registration and proof claims cannot be replayed onto main's KAP-49 contract.
This package rewrites durable intent from `31ed46b5` and `b66a4001` as an
independent default-off implementation experiment, not fulfillment of the
accepted `reconcile-linux-node-source-dev-contract` change.

## What Changes

- Add separately selected `vllm_poc` behind existing local gRPC and loopback
  HTTP `/v1/completions` on 58080, with logical load/unload and concurrency one.
  N-slot admission remains deferred because `SPEC.md` §7.5.3 requires stream-mode
  Node and placement concurrency one; no SPEC amendment is authorized here.
- Preserve rendered prompts and legacy-blended generated reasoning; use stateful
  framing only to locate an unambiguous final suffix for fail-closed Qwen XML
  tool parsing. Raw output passes through at thinking length or malformed
  reasoning framing; tool marker prefixes remain text at clean stop, not length.
  Emit safe text incrementally, and reject required/named tool choices when raw
  passthrough cannot provide a parsed call. Accept the exact closed-empty-think
  prompt suffix without registering a new effort profile.
- Decode tool parameters by declared property type, retaining raw strings and
  vLLM qwen3 JSON-or-trimmed-text fallback for absent or unknown types, without
  claiming general JSON Schema validation.
- Require pinned sampling and bounded total decoded output, forward authoritative
  prompt IDs when present (rendered string otherwise), reject token-ID output and
  logprobs, and use UUID tool-call IDs under KAP-116.
- Keep cancellation transports request-scoped. Report native cessation as
  unconfirmed and deny new admission after unconfirmed cleanup. Confirmed polling
  is blocked because pinned vLLM has no request-scoped, fresh cessation receipt;
  aggregate metrics cannot prove it. Record the limitation in ADR 0037.
- Keep historical setup and live runner disabled; retain deterministic evidence
  only. No new Controller/shared/tokenizer registration or public final-only
  contract is introduced.

## Capabilities

### New Capabilities

- `linux-source-dev-inference-poc`: bounded Worker experiment and execution gates.

### Modified Capabilities

None. Platform qualification contracts remain unchanged.

## Impact

No `SPEC.md` change is required. ADR 0037 records the source-development boundary.
`SPEC.md` §1.4, §1.5, §4.10, §7.2.9, M9 and ADR 0035 remain authoritative and
unchanged. This proposal grants no live execution, native cessation, custody,
capacity, model/provider/platform qualification or support. Historical acceptance
does not accept this revision; no current-main real API/OpenCode proof is claimed.
