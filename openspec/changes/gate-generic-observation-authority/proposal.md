# Gate generic observation authority

## Why

Issue #396 found that generic Runtime Endpoint observation paths persisted admission
candidates and Node metadata while a Controller was configured as standby or had
unproven leadership. The authenticated observation path already checks the
leader-only lifecycle write gate.

## What changes

- Apply the existing `:node_lifecycle` write gate to generic status and
  candidate-only observation entry points.
- Keep denial non-durable and candidate-only observation queue-inert.
- Permit only strictly freshness-qualified, original-target-owned source invalidation
  on denied generic status, without immediate queue promotion.

## Scope

This change does not add transaction-held leadership fencing, Controller-wide queue
ownership, durable dispatch permits, or Allocation release behavior.
