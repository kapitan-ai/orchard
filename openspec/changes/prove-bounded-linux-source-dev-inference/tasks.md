## 1. Current-main contract review

- [x] 1.1 Confirm no SPEC.md amendment is required (§1.5) and record the boundary in ADR 0037.
- [x] 1.2 Validate this change and all OpenSpec packages strictly; record results without importing historical completed tasks.

## 2. Deterministic implementation verification

- [x] 2.1 Verify default-off local gRPC/loopback HTTP selection, logical load/unload, concurrency one and unsupported-input rejection.
- [x] 2.2 Verify legacy-blended raw pass-through, unambiguous final-suffix tool parsing, UUID calls, stop/length marker-prefix distinctions, parameter decoding and total decoded-output bounds with fake providers.
- [x] 2.3 Verify historical setup and runner main/execute refuse before mutation; keep live execution disabled.

## Slice 2. Model-free Worker parity

- [x] S2.1 Stream reasoning/raw text and safe final prefixes incrementally; preserve split markers, raw passthrough and clean-stop/length distinctions.
- [x] S2.2 Forward authoritative prompt IDs using the inspected vLLM 0.27.1 schema, fall back only when absent and retain strict usage equality.
- [x] S2.3 Preserve request-scoped disconnect, report unconfirmed native cessation and latch unhealthy admission.
- [ ] S2.4 Confirm native cessation through bounded provider polling. Blocked: pinned vLLM has no request-scoped fresh receipt or execution fence; aggregate metrics cannot prove it. ADR 0037 records options rather than an invented confirmed test path.
- [ ] S2.5 Add N-slot admission and matching supervisor sequence limit. Stopped: SPEC.md §7.5.3 requires stream-mode Node and placement concurrency one. Retain the existing single-slot behavior; ADR 0037 records the separately approved amendment or deferral options.
- [x] S2.6 Accept the exact template's thinking-disabled legacy prompt suffix without adding a tokenizer effort profile.
- [x] S2.7 Fail required/named tool choice when malformed/truncated reasoning framing forces raw passthrough.
- [x] S2.8 Run the pinned validation workflow and independent full-diff review; record public-safe results in the draft stacked PR handoff. The review's stream-concurrency contract finding is resolved by deferring S2.5, not changing SPEC.md.

## 3. Separately reviewed future work (not authorized)

- [ ] 3.1 Decide between rebuilding the exact qualified KAP-49 fixture with reviewed provenance under current registration and accepting a separate new artifact profile.
- [ ] 3.2 Obtain separate owner approval of exact clean source, tuple, required supervisor inputs, bounded mutation and cleanup before any download, supervisor or inference execution.
- [ ] 3.3 Only after that approval, define and review new real API/OpenCode evidence and cleanup assertions; no current proof or qualification is inferred.

Final-only projection requires a separate public contract, not completion of
these tasks. This package does not complete the accepted Linux Node change.
