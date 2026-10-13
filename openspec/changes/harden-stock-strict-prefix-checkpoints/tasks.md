# Tasks: harden strict-prefix checkpoint reuse

## 1. Additive compatibility

- [x] 1.1 Map `strict_prefix_runtime_unsupported`, `strict_prefix_model_unsupported` and the older `strict_prefix_checkpoint_unsupported` to RUNTIME_UNAVAILABLE, and `insufficient_memory` to RESOURCE_EXHAUSTED, in the Node Agent. Test the Node mapping, and that the Controller keeps each code and retries both categories on another Node.
- [x] 1.2 Add `checkpoint_uncertain_count` and `checkpoint_retained_bytes` to the Worker and cluster prefix-cache status messages, and regenerate the bindings and descriptor. The N-1 fixture is unchanged.
- [x] 1.3 Serialize, pass through and normalize the counters. The Controller keeps them only for `strict_prefix`, and the capture policy accepts `strict_prefix` and `trie`.
- [x] 1.4 Update SPEC.md §7.5.3 for the new fields.

## 2. Activation

- [ ] 2.1 Add the per-model settings file, its resolver and the fixed launch policy. Refuse invalid combinations before spawn.
- [ ] 2.2 Add `strict_prefix` to the Worker CLI with explicit strict-prefix flags. Remove the environment variables, and launch Workers with the old enabling variable removed.
- [ ] 2.3 Emit the new load-refusal codes, require `observe` memory mode, and subtract the configured budget once from published headroom.
- [ ] 2.4 Publish strict-prefix status from the Worker service, including the counters, and log requests that end before prefill.
- [ ] 2.5 Restrict the fingerprint buffer, publication, scoring and the prefix-cache capability to `kv` and `trie`.
- [ ] 2.6 Test old and new Node and Worker versions in both directions, and update `docs/local-dev.md`.

## 3. Validation

- [ ] 3.1 Run the Elixir and Python/native workflows, and strict OpenSpec validation.
- [ ] 3.2 Update the spike change's task 5.3 when activation lands.
