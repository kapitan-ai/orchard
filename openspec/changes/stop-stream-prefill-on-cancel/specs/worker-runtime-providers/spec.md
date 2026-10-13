## ADDED Requirements

### Requirement: Stream-mode prefill stops at the next chunk boundary on cancel
When the MLX-LM Worker runs in stream mode and a request is cancelled during prefill, the Worker SHALL stop the prefill at the next intermediate prefill chunk boundary and end the request with exactly one `cancelled` terminal (SPEC.md §12.4). A cancel after the last prompt token SHALL be handled on the decode cancel stride. The shared batch runtime SHALL keep its own cancellation behavior.

#### Scenario: Cancel during a long prefill
- **WHEN** the cancel event is set while the Worker is prefilling a prompt in stream mode
- **THEN** no further prefill chunk is evaluated after the next chunk boundary, no output is emitted, and the request ends as `cancelled`

#### Scenario: Worker serves the next request
- **WHEN** a prefill was stopped by a cancel
- **THEN** the session cache is cleared as for any finished request, and the next request on the same Worker generates normally

#### Scenario: Checkpoint at the cancel boundary
- **WHEN** strict-prefix checkpoint reuse is enabled and the cancel arrives at the boundary chosen for capture
- **THEN** the checkpoint is captured before the prefill stops and stays available to a later request

#### Scenario: Cancel at the final prefill callback
- **WHEN** the cancel event is set only when the final `(total, total)` progress callback runs
- **THEN** the Worker does not stop there, and the decode cancel stride ends the request as `cancelled`
