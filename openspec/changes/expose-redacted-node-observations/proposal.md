## Why

Runtime Endpoint status already carries volatile host inventory, but generic runtime snapshots discard it. Operators need bounded evidence without mistaking it for persisted Node inventory or scheduling authority.

## What Changes

- Add a pure allowlist projection to existing runtime-target snapshots and the shared NodeStatus contract.
- Expose re-normalized nullable `runtime.diagnostics` in the existing authenticated `GET /ops/v1/health` response, using its single existing snapshot read and unchanged authorization/readiness behavior.
- Expose evidence states, source categories, original timestamps and ages, CPU/network/vendor device counts, and runtime health and worker-state categories.
- Keep registered Node and admission-candidate diagnostics null; no new probes or identity bindings.
- Keep broader logs and metrics work deferred and support bundles retired.

## Capabilities

### New Capabilities

- `redacted-node-observations`: bounded runtime-target diagnostic projection.

## Impact

Clarifies SPEC.md §4.6.1 and implements a bounded part of Milestone 9 diagnostics. No persistence, readiness, admission, custody, release, capacity, scheduling, dispatch, trust, transport, provider qualification, or distribution change.
