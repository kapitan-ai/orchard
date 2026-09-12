## ADDED Requirements

### Requirement: Worker reasoning evidence is bound to one loaded artifact

A future Worker Runtime reasoning envelope SHALL be scoped to exactly one `WorkerLoadedBinding` and one `service_incarnation`. Each complete advertised tuple SHALL contain the `SPEC.md` §7.5.3a eleven fields — generation policy, projection, reasoning effort, model artifact digest, chat-template digest, render contract, render contract version, parser family, parser version, runtime contract version, and event-binding version — match that binding's artifact digest, and resolve its selected profile exactly once in the enclosing capability envelope. A present incomplete envelope, duplicate or conflicting tuple, unknown required value, or missing loaded binding SHALL prove no reasoning support rather than legacy omission.

The `SPEC.md` §7.5.3a allocation this delta traces places the deferred `WorkerCapabilities.loaded_binding` at field 8, its sibling reasoning envelope at field 9, and the shared cross-boundary definitions in `proto/cluster/v1/reasoning.proto`. Implementation SHALL re-confirm those allocations and SHALL block rather than substitute a conflicting number or shape. That shared file makes the provider-neutral Worker Runtime boundary depend on `cluster.v1`; its relocation or removal SHALL be sequenced by the later `cluster.v1` deprecation alongside the existing Worker Runtime imports, and SHALL NOT be attempted by this contract or its implementation.

This acceptance delta adds no protocol source declaration. The complete owner-confirmed schema decision record is in `design.md` §2.1: it fixes the effort wrapper encoding, `WorkerLoadedBinding` tags and strings, outer `service_incarnation` association, field 9 envelope, opt-in live-observation carrier, WorkerRuntimeService-only `PrepareInference`, frozen-input/proof/redemption shape, 16-byte loaded-instance identity, 32-byte authorization, presence-aware `Failed.usage`, and typed-event deferral. It remains documentation-only here; declaration and implementation work stay blocked by `design.md` §1 condition 3. Because tuple comparison is byte-exact, an omitted `reasoning_effort` remains distinguishable from every selected tier so an absent-effort advertisement cannot prove a tier-selected tuple.

Load replacement, unload, failed destructive unload, or Worker Runtime teardown SHALL invalidate advertised reasoning evidence and any preparation authorization for the affected loaded instance.

#### Scenario: Same worker process reloads an artifact

- **WHEN** the Worker Runtime reloads an artifact without changing `service_incarnation`
- **THEN** prior reasoning evidence and preparation authorization are invalid
- **AND** the Worker must publish fresh evidence for the new loaded binding before negotiated execution

#### Scenario: Terminal failure has known zero output

- **WHEN** a Worker-originated terminal failure proves exact cumulative output usage of zero
- **THEN** the future presence-aware failure usage field is present with zero
- **AND** absence remains distinct missing evidence
