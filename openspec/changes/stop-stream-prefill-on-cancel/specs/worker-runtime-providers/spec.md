## ADDED Requirements

### Requirement: Stream-mode prefill stops at the next chunk boundary on cancel
When the MLX-LM Worker runs in stream mode and a request is cancelled before its last prefill chunk, the Worker SHALL stop the prefill at the next intermediate prefill chunk boundary and end the execution with exactly one Worker `cancelled` terminal (SPEC.md §12.4). The Request and attempt outcome follow their existing rules. A cancel during the last prefill chunk or after prefill SHALL be handled on the decode cancel stride, so a reply that ends before the next stride check can still complete. The shared batch runtime SHALL keep its own cancellation behavior.

#### Scenario: Cancel during a long prefill
- **WHEN** the cancel event is set while the Worker is prefilling a prompt in stream mode, before its last prefill chunk
- **THEN** no further prefill chunk is evaluated after the next intermediate chunk boundary, no output is emitted, and the execution ends with the Worker `cancelled` terminal

#### Scenario: Worker serves the next request
- **WHEN** a prefill was stopped by a cancel
- **THEN** the session cache is cleared as for any finished request, and the next request on the same Worker generates normally

#### Scenario: Checkpoint at the cancel boundary
- **WHEN** strict-prefix checkpoint reuse is enabled and the cancel arrives at the boundary chosen for capture
- **THEN** the checkpoint is captured before the prefill stops and stays available to a later request

#### Scenario: Cancel at the final prefill callback
- **WHEN** the cancel event is set only when the final `(total, total)` progress callback runs, after the first output token was sampled
- **THEN** the Worker does not stop there; the existing decode cancel check applies, so the execution ends with the Worker `cancelled` terminal at the next decode cancel stride, or completes normally if generation ends before that stride
