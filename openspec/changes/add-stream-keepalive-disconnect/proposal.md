# Detect a caller disconnect during a silent streaming execution

## Why

A streaming request finds a closed client socket only when the Controller writes to it.
Bandit gives the request process no other signal.
While a Runtime Endpoint execution produces no output, for example during a long prefill, the Controller writes nothing.
A hardware run with a 131k-token prompt showed the cost: the client closed its socket 30 s after sending, but the cancel reached the Worker only at its first token, 556 s later.
During that time the only generation slot stayed busy, and a new request got `cluster_busy`.

## What changes

- While a streaming execution is in progress and before its terminal event, the Controller writes the SSE comment line `: keepalive` at a configured interval (`sse_keepalive_interval_ms`, default 5 seconds).
- A failed keepalive write cancels the attempt through the existing caller-disconnect path (`request_caller_disconnect`, retry decision `cancelled`).
- A keepalive comment is transport framing only. It is not persisted, counted, or treated as output, Output Commitment, acceptance, or a retry input.
- No keepalive is written after the terminal event, `[DONE]`, or a stream error.
- A keepalive probe that fails for any other reason stops probing and does not fail the attempt.
- Both `POST /v1/chat/completions` and `POST /v1/responses` streams use it. Non-streaming routes and the Console playground do not.

## Out of scope

- Queue, scheduling, model-load, and capacity-gate waits before execution. They are bounded separately and are not probed.
- Interrupting a prefill inside a runtime. The Worker still stops at its next cancellation check.

## Impact

- `SPEC.md` §5.9 states the rule; §7.2.4 and §7.2.5 refer to it.
- Code: `Orchard.API.SSE`, `Orchard.API.InferenceControllerSupport`, both streaming controllers, `Orchard.Inference.RequestOrchestrator` (option threading), `Orchard.Dispatch.RequestDispatcher` (probe in the execution receive loop), and the inference configuration.
