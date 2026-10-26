# Design: harden strict-prefix checkpoint reuse

## Context

Every Worker setting is Node-global today. The Node starts one Worker process per model. `WorkerRuntimeAdapter.load_model/2` reads each setting from the global configuration and builds the Worker arguments. The Worker process inherits the Node's environment, which is how the spike's environment variables reach it.

## Decisions

### Per-model launch policy

A Node setting names a file that maps exact `model_id@version` keys to Worker settings: prefix-cache mode, generation mode, memory-budget mode, and the strict-prefix slots, slot bytes, budget bytes and reply marker. The Node parses the file at startup with OTP `:json`, so source development and releases use the same code. A resolver applies global defaults, then global settings, then the exact model override, and returns one fixed, versioned launch policy. Each Worker process keeps that policy for its lifetime, and the policy reaches the Worker arguments unchanged. Strict-prefix launches always write the generation and memory flags, because the Worker's own defaults are `batch` and `observe`.

The resolver refuses `strict_prefix` before spawn unless the backend is `mlx`, the generation mode is `stream` and the memory-budget mode is `observe`. It never rewrites a setting to make a combination valid. `observe` is required, not `disabled`, so that the Worker can check the budget against known headroom.

A later qualification change can bind a digest of the resolved policy into the loaded offer. The policy is resolved after every override, so nothing changes it after that binding.

### Node capacity and memory

A stream-mode Worker reports one generation. The Node takes the lowest limit across loaded Workers, so a strict-prefix model limits the Node to one active request. This change keeps that rule. Per-model limits do not show that a mixed Node is safe for host memory, because each model checks headroom only against itself.

Enforce mode stays refused for strict-prefix models. Per-model memory mode lets a Node that enforces other models run the strict-prefix model in `observe`. A future design that evicts checkpoints under pressure must drop only retained, unborrowed checkpoints, keep uncertain charges, settle and sample again, and abort only if pressure remains. It must not reuse the store's `clear()`, which also drops uncertain slots.

### Headroom

Published headroom is `max(0, target - resident - overhead - configured checkpoint budget)`, and recommended context comes from that figure. The full configured budget is used, not the current occupancy, so the figure does not promise memory that later captures consume. The load check compares the budget with headroom before the subtraction, so the budget is counted once. `target_working_set_bytes` does not change.

### Status

The Worker reports `implementation = "strict_prefix"` through the existing prefix-cache fields:

- `entry_count` is retained checkpoints;
- `total_bytes` is the fixed charge for occupied slots;
- `configured_max_entries` and `configured_max_bytes` are slots and budget;
- `failures` is restore and copy failures.

The added fields are plain proto3 scalars, because the Worker contract test forbids `optional`. Other implementations report zero, and the Controller keeps the fields only for strict-prefix status. The Worker service no longer short-cuts strict-prefix status to `disabled`.

### Fingerprints and capability

The Worker turns the fingerprint buffer, fingerprint publication, fingerprint scoring and the prefix-cache capability on only for the `kv` and `trie` implementations. The current fingerprint hashes only the first 8,192 bytes of the rendered prompt and cannot identify a checkpoint. If a strict-prefix Worker published it, the Controller would count the Node as warm for a store that cannot score it.

### Migration

The new Node launches each Worker with the old enabling variable removed from its environment. An older Worker started by the new Node therefore runs without reuse instead of refusing. A new Worker that still sees the old variable refuses with a message that names it.

## Risks

- A mixed Node can overcommit host memory. Qualification runs the tuple alone on its Node.
- Rolling back to an older Worker needs the per-model `strict_prefix` setting removed first, because older Workers reject the mode value.
