## ADDED Requirements

### Requirement: Streaming keepalive detects a caller disconnect
While a Runtime Endpoint execution for a streaming request is in progress and before its terminal event, the Controller SHALL write the SSE comment line `: keepalive` at the configured interval.
A failed keepalive write SHALL be a caller disconnect: it SHALL cancel the attempt and persist `cancelled`, durable code `request_caller_disconnect`, and retry decision `cancelled`, with no further attempt.
A keepalive comment SHALL NOT be persisted, counted, or treated as output, Output Commitment, acceptance, or a retry input.
The Controller SHALL NOT write a keepalive after the terminal event, `[DONE]`, or a stream error.
A keepalive probe that fails for any other reason SHALL stop probing and SHALL NOT fail the attempt.
This requirement traces to `SPEC.md` §5.9, §7.2.4, and §7.2.5.

#### Scenario: Client closes its socket during a long prefill
- **WHEN** a streaming execution produces no output and the client closes its socket
- **THEN** the next keepalive write fails
- **AND** Orchard cancels the attempt as `request_caller_disconnect` without waiting for the first output token
- **AND** no further attempt follows

#### Scenario: Keepalive comments do not change attempt evidence
- **WHEN** keepalive writes succeed during an execution that then completes
- **THEN** the attempt events, delivered event count, Output Commitment, and usage equal those of the same execution without keepalive writes
- **AND** no keepalive comment follows the terminal event
