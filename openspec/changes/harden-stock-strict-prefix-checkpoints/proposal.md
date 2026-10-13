## Why

Strict-prefix checkpoint reuse is on main as a default-off spike (change `add-stock-strict-prefix-checkpoints`). Inherited `ORCHARD_WORKER_STRICT_PREFIX_*` environment variables enable it for every Worker on a Node. Those settings conflict with other models on the same Node, and the operator cannot see why a model was refused. The published headroom also ignores the checkpoint budget, and prefix-cache status reports `disabled`. Before the first qualified tuple can use it, it needs a real configuration mode, clear refusals, correct accounting and visible status.

## What Changes

- Add `strict_prefix` as a Worker prefix-cache mode, enabled for an exact `model_id@version` through a Node setting. A resolver applies precedence (global defaults, then global settings, then the exact model override) and gives each Worker one fixed launch policy. The Node refuses an invalid combination before it starts the Worker.
- Remove the `ORCHARD_WORKER_STRICT_PREFIX_*` environment variables. The Node removes the old enabling variable from each Worker's environment, so a mixed old and new installation cannot turn the mode on for every model.
- Split Worker load refusals into stable codes and map them in the Node Agent:
  - `strict_prefix_runtime_unsupported` and `strict_prefix_model_unsupported` map to RUNTIME_UNAVAILABLE;
  - `insufficient_memory` maps to RESOURCE_EXHAUSTED;
  - the older `strict_prefix_checkpoint_unsupported` maps to RUNTIME_UNAVAILABLE.

  All three categories stay retryable on another Node.
- Subtract the configured checkpoint budget once from the published headroom and recommended context.
- Publish strict-prefix status through the prefix-cache status, and add two counters to the Worker and cluster status messages: the uncertain checkpoint count and the measured retained bytes.
- A strict-prefix Worker publishes no cache-affinity fingerprints and no prefix-cache capability. Checkpoint-identity affinity is a separate change.

## Impact

SPEC.md behavior change. §7.5.3 gains the two additive `RuntimePrefixCacheStatus` fields and states that the Controller keeps them only for `implementation = "strict_prefix"`. The capture allowlist also accepts the `strict_prefix` and `trie` implementation values. The mode stays opt-in and unqualified. Promotion to a supported mode for a qualified tuple stays with the runtime decision, and native evidence with the qualification campaign. Behavior is unchanged on any Node with no strict-prefix model loaded. Loading one limits that Node to one active request, because the Node takes the lowest Worker limit. Co-resident models each check memory only against themselves, so qualification runs the tuple alone on its Node.
