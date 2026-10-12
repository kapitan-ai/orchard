# Tasks: detect a caller disconnect during a silent streaming execution

## 1. Contract

- [x] 1.1 State the keepalive rule in `SPEC.md` §5.9 and refer to it from §7.2.4 and §7.2.5.
- [x] 1.2 Run strict OpenSpec validation for this change package.

## 2. Implementation

- [x] 2.1 Add `SSE.send_keepalive/1` and the `sse_keepalive_interval_ms` setting.
- [x] 2.2 Pass `:keepalive_handler` and `:keepalive_interval_ms` from both streaming controllers through `RequestOrchestrator` to `RequestDispatcher`.
- [x] 2.3 Probe in the execution receive loop as a receive timeout, stop at the first terminal event, and cancel as a caller disconnect on a failed write.

## 3. Tests

- [x] 3.1 Dispatcher: a failed probe before and after acceptance is a caller disconnect; successful probes change no attempt evidence and stop at the terminal; a raising probe stops probing; invalid options are refused.
- [x] 3.2 Orchestrator: a failed probe during a silent execution persists `cancelled`, HTTP `499`, `request_caller_disconnect`, and retry decision `cancelled`, with no attempt 2.
- [x] 3.3 Controllers: both streams write the comment before data and never after the terminal; a failed write marks the stream closed and cancels.
- [ ] 3.4 Native: rerun the long-prefill disconnect case and confirm the Worker gets the cancel within the interval plus one prefill chunk.
