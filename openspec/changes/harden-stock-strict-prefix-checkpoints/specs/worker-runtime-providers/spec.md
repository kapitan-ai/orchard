## ADDED Requirements

### Requirement: Per-model strict-prefix mode
The Node Agent SHALL enable strict-prefix checkpoint reuse only for a model whose exact `model_id@version` has the `strict_prefix` prefix-cache mode in the Node's per-model Worker settings. It SHALL resolve each Worker's settings once, in the order global defaults, global settings, exact model override, and SHALL keep that launch policy for the life of the Worker. It SHALL refuse a strict-prefix policy before starting the Worker unless the backend is `mlx`, the generation mode is `stream` and the memory-budget mode is `observe`, and it SHALL NOT rewrite any setting to make a policy valid. Models without the override SHALL keep their existing settings.

#### Scenario: Other models on the same Node
- **WHEN** one model has the strict-prefix override and another model on the same Node does not
- **THEN** the other model launches with the global settings and loads as before

#### Scenario: Invalid strict-prefix policy
- **WHEN** a strict-prefix override resolves to a generation mode other than `stream` or a memory-budget mode other than `observe`
- **THEN** the Node refuses the load before it starts the Worker, and reports why

#### Scenario: Old enabling variable present
- **WHEN** the Node's environment still sets the spike's strict-prefix enabling variable
- **THEN** the Node launches each Worker with that variable removed, so it enables reuse for no model

### Requirement: Strict-prefix load refusals are retryable node conditions
The Node Agent SHALL map the Worker codes `strict_prefix_runtime_unsupported`, `strict_prefix_model_unsupported` and `strict_prefix_checkpoint_unsupported` to the RUNTIME_UNAVAILABLE load-failure category, and `insufficient_memory` to RESOURCE_EXHAUSTED, each with a sanitized message and the code preserved. These refusals describe the Node's configuration, not the model artifact, so the Controller SHALL be able to retry the request on another Node.

#### Scenario: Unsupported model cache layout
- **WHEN** a Worker refuses a strict-prefix load because the model's cache layout is unsupported
- **THEN** the load fails as RUNTIME_UNAVAILABLE with code `strict_prefix_model_unsupported`, and the request is eligible for another Node

#### Scenario: Older Worker refusal code
- **WHEN** an older Worker refuses with `strict_prefix_checkpoint_unsupported`
- **THEN** the load fails as RUNTIME_UNAVAILABLE with that code instead of a generic internal failure

### Requirement: Checkpoint budget in published headroom
When strict-prefix reuse is enabled for a model, the Worker SHALL subtract the full configured checkpoint budget once from the published estimated headroom, floored at zero, and SHALL derive the recommended context tokens from that figure. It SHALL check whether the budget fits against headroom before the subtraction, and SHALL NOT change the target working set.

#### Scenario: Budget equals headroom
- **WHEN** the configured budget equals the headroom before subtraction
- **THEN** the model loads, and published headroom and recommended context are zero

### Requirement: Strict-prefix status
When strict-prefix reuse is enabled, the Worker SHALL report prefix-cache status with implementation `strict_prefix`: retained checkpoints as the entry count, the fixed charge for occupied slots as total bytes, slots and budget as the configured maximums, and the uncertain checkpoint count and measured retained bytes in their own fields. The Controller SHALL keep the checkpoint fields only from an `ok` `strict_prefix` status. A strict-prefix Worker SHALL publish no cache-affinity fingerprints and SHALL NOT advertise the prefix-cache capability.

#### Scenario: Status of a strict-prefix Worker
- **WHEN** the Controller reads the status of a strict-prefix Worker that holds one retained and one uncertain checkpoint
- **THEN** it sees implementation `strict_prefix`, entry count 1, uncertain count 1, and no fingerprints

#### Scenario: Strict-prefix status that is not ok
- **WHEN** a strict-prefix Worker reports status `error`, `unavailable` or `invalid_status`, with or without nonzero counters
- **THEN** the Controller records no checkpoint counters for it

#### Scenario: Other implementations
- **WHEN** a `kv` Worker reports zero checkpoint counters
- **THEN** the Controller records no checkpoint counters for it
