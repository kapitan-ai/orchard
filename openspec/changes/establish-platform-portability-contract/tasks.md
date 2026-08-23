## 1. Reconcile The Normative Contract

- [x] 1.1 Amend `SPEC.md` to define portable invariants, platform profiles, Controller Hosts versus schedulable Nodes, heterogeneous runtime vocabulary, the first Linux Controller/macOS MLX Node target, and a vNext platform-expansion milestone without rewriting completed Mac acceptance or claiming unimplemented support.
- [x] 1.2 Add a platform-profiles decision record covering dependency direction, Mac all-in-one preservation, the Linux Controller target with external Postgres, the support acceptance gate, and deferred Linux Node packaging and runtime choices.
- [x] 1.3 Add a decision record that assigns durable operator authority to Controller-owned authenticated operations, portable client behavior to the CLI, and lifecycle authority to platform host tooling.
- [x] 1.4 Add a decision record for provider-neutral Worker Runtime contract ownership, generated bindings, version negotiation, and compatibility policy.
- [x] 1.5 Add a decision record separating host capability providers from runtime providers and defining normalized device and memory-domain vocabulary.
- [x] 1.6 Amend decisions 0001, 0003, 0006, 0011, 0012, 0013, and 0018 only where platform scope or mixed-platform acceptance changes, preserving their security, transport, scheduling, release, and lifecycle invariants.
- [x] 1.7 Reconcile architecture, tooling, local-development, packaging, glossary, and contributor documentation with the accepted profile, support status, and ownership terms.
- [x] 1.8 Run strict validation for this change and the complete OpenSpec corpus, then review the resulting main and delta specs for incomplete or contradictory prose.
- [ ] 1.9 Obtain collaborator review of the contract and decisions before any implementation child change begins.

## Follow-up Delivery Boundaries

Implementation is outside this contract-only change.
Umbrella issue #266 owns the dependency map, and issue #267 owns this contract reconciliation.
After contract acceptance, create focused native child issues and separate OpenSpec changes as applicable for:

1. Darwin native-helper eviction from portable CLI compilation.
2. Dependency-aware Linux portability and provider-neutral conformance validation.
3. Controller release decoupling from CLI implementation.
4. Provider-neutral Worker Runtime protocol ownership and generated bindings.
5. Additive normalized runtime, acceleration, device, memory-domain, and failure contracts.
6. Capability-provider implementations and conformance.
7. Managed host-lifecycle adapters that preserve ADR 0018.
8. Incremental CLI command-family migration to Controller-owned authority.
9. Linux Controller release and mixed-platform acceptance.

Do not represent these follow-up boundaries as completed tasks in this change.
