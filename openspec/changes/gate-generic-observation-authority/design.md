# Design: generic observation authority gate

The generic methods own the missing boundary, so the gate belongs before their
normalization and persistence transactions. Reusing authenticated ingestion would
change the intentionally separate heartbeat and trust semantics.

On denial, target resolution uses the original configured target rather than status
payload identity. A valid Controller observation time must be strictly newer than the
resolved Node heartbeat, unless no heartbeat exists. The clear operation always uses
`promote?: false`; it removes stale local hints but does not become a dispatch fence or
release existing allocations.

Candidate-only observation never owns queue sources, so denial has no queue side
effect. This preserves its existing queue-inert contract.
