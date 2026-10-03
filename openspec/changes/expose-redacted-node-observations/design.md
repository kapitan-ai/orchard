## Context

The Node Agent asynchronously collects inventory into a volatile ETS snapshot. Runtime Endpoint adapters bound that snapshot. OrchardConsole.Runtime already reads status through those adapters, but its normalized snapshot omits inventory. Persisted Nodes and heartbeat payloads deliberately have no host inventory.

## Decisions

Use the existing runtime-target snapshot seam. A pure shared projection produces an additive diagnostics block; NodeStatus normalizes the same block without contacting a runtime. Registered-node CLI list/inspect retain their existing status and emit null diagnostics. Do not use hostname/display-name matching to attach host observations to Nodes.

The operator-facing surface is the existing authenticated `GET /ops/v1/health` response, not an uncalled status builder or a new UI. Its runtime summary includes nullable `diagnostics`, re-normalized by the shared projection from its single existing snapshot read. Only successful snapshots may contribute diagnostics; failed snapshots suppress even injected valid blocks. Legacy/missing blocks and unknown schemas yield null. Cluster-scoped Operator-or-admin authorization, no-store caching, health status and public status-only readiness remain unchanged.

The projection admits only fixed categories, timestamps, ages and counts. It omits byte capacities, raw health messages/codes, device identities, network identity, evidence paths and arbitrary strings. Unknown protobuf fields never appear in output. A bounded preflight limits traversal before inventory validation; oversized or malformed evidence fails closed.

Inventory freshness uses its source timestamp with a conservative 195000 ms ceiling (the default Agent snapshot lifetime); each section must also have valid fresh evidence. Runtime health/lifecycle observation uses the Controller observation timestamp with a 15000 ms ceiling. Future or missing timestamps are invalid/unavailable, never fresh. These are diagnostic bounds only, not scheduler clocks or qualification claims. Re-reading a normalized block recomputes ages from original timestamps rather than refreshing evidence.

## Compatibility and risks

The status contract remains v1 with an additive nullable diagnostics field. Old readers may ignore it; new readers treat a missing field as null. Missing/disabled inventory is absent, not healthy or zero capacity. Counts describe observations, not available resources. The existing authenticated/local operator boundaries and public status-only readiness are unchanged. Existing diagnostic fields retain their meanings; the redaction guarantee applies to the new block, not to a wholesale export of legacy status.

## Non-goals

No new support command, bundle, archive, export, staging, or manifest. No UI expansion, OS/vendor probes, runtime calls, persistence, logs/metrics breadth, worker recovery, credentials, transport, proto or packaging changes.
