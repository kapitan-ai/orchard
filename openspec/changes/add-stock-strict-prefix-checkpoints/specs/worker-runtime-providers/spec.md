## ADDED Requirements

### Requirement: Default-off strict-prefix checkpoint reuse
The stock MLX Worker SHALL provide strict-prefix checkpoint reuse only when the operator explicitly enables it. When it is not enabled, the Worker SHALL keep its existing prefix-cache, generation-mode and model behavior. The setting SHALL NOT change the MLX-LM runtime foundation, admission, scheduling, Node status or public APIs.

#### Scenario: Setting not enabled
- **WHEN** the Worker starts without strict-prefix reuse enabled
- **THEN** the configured `kv`, `trie` or `disabled` prefix-cache mode applies exactly as before, and no strict-prefix checkpoint is captured or restored

### Requirement: Capture only at an intermediate prefill boundary
When strict-prefix reuse is enabled, the Worker SHALL capture a checkpoint only from an intermediate prompt-progress callback that reports fewer processed tokens than the prompt total. The capture boundary SHALL be an absolute multiple of the prefill step at or before the last reply marker. The Worker SHALL NOT capture at the final prompt-progress callback or at the end of a response.

#### Scenario: Final progress callback
- **WHEN** the prompt-progress callback reports the processed count equal to the total, after the first sampled token went through the lookahead step
- **THEN** no checkpoint is captured from that callback

#### Scenario: No boundary before the reply marker
- **WHEN** the prompt has no reply marker, or no prefill-step multiple lies after the restored prefix and at or before the last reply marker
- **THEN** the request captures no checkpoint and generates normally

### Requirement: Exact, strictly shorter prefix restore
The Worker SHALL restore a checkpoint only when its token key is an exact prefix of the request that is strictly shorter than the request, and SHALL prefill the remaining suffix. It SHALL NOT trim or truncate any cache state.

#### Scenario: Follow-up turn extends the stored prefix
- **WHEN** a request starts with every token of a retained checkpoint and has more tokens after it
- **THEN** the Worker restores the longest such checkpoint and prefills only the suffix, and the output equals an uncached run under greedy decoding

#### Scenario: Changed earlier turn
- **WHEN** a request differs from a retained checkpoint at any position inside the checkpoint's key
- **THEN** the lookup misses and the request prefills from the start

#### Scenario: Request equals a stored key
- **WHEN** a request has exactly the tokens of a retained checkpoint and no more
- **THEN** the lookup misses

### Requirement: Owned checkpoint state with reserved memory
The Worker SHALL deep-copy every cache layer when it stores and when it restores a checkpoint, so later changes to a working cache or a restored copy cannot change a retained checkpoint. It SHALL reserve a fixed slot charge before each copy. A copy that fails or is uncertain SHALL keep its reservation until the store is cleared at unload, and its key SHALL NOT be captured again before then.

#### Scenario: Working cache changes after capture
- **WHEN** generation continues on the working cache after a checkpoint was captured from it
- **THEN** a later restore of that checkpoint returns the state at the capture boundary

#### Scenario: Copy fails
- **WHEN** the deep copy or its materialization raises during a capture
- **THEN** the slot stays charged as uncertain until unload, a repeated capture of the same key is skipped, and no healthy checkpoint is evicted for it

#### Scenario: Restore fails
- **WHEN** the deep copy or materialization of a retained checkpoint fails during a lookup
- **THEN** the request prefills from the start and the unrestorable checkpoint is dropped

### Requirement: Refuse unsupported strict-prefix configurations
When strict-prefix reuse is enabled, the Worker SHALL refuse startup or model load unless the backend is `mlx` in stream mode with prefix-cache mode `disabled`, memory-budget mode is `disabled` or `observe`, mlx-lm is the pinned version and commit, the model cache uses only `KVCache` and `ArraysCache` layers, and the checkpoint budget holds every configured slot and fits known memory headroom.

#### Scenario: Budget cannot hold the slots
- **WHEN** the configured budget is smaller than the slot count multiplied by the slot charge
- **THEN** the Worker refuses to start

#### Scenario: Different mlx-lm build
- **WHEN** the installed mlx-lm reports a different version or was not installed from the pinned commit
- **THEN** the model load is refused before weights load, with a strict-prefix refusal code
