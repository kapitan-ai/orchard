## 1. Contract shaping

- [x] 1.1 Inspect `kapitan` hardware, cached runtime identity, and current Worker Runtime and scheduling boundaries read-only.
- [x] 1.2 Select one exact runtime/provider/model/tokenizer/hardware tuple and record provenance, license, sizes, 131,072-input plus output-reserve envelope, resources, ports, and stop conditions.
- [x] 1.3 Record ADR 0039, SPEC impact, proof-only shortcuts, direct-API and isolated OpenCode evidence, cleanup, and KAP-18/KAP-26/KAP-85 deferrals.
- [ ] 1.4 Obtain explicit Repository Owner acceptance of the contract and bounded implementation plan.

## 2. Implementation (not authorized)

- [ ] 2.1 Add the development-only Worker Runtime adapter and fake-provider tests without changing production provider authority.
- [ ] 2.2 Add disposable unmanaged scheduling setup and cleanup for one tenant, API key, exact model, grant, and local target.
- [ ] 2.3 Validate formatting, compilation, strict static analysis, focused tests, coverage, protocol conformance, and strict OpenSpec.
- [ ] 2.4 Obtain explicit Repository Owner acceptance of the exact clean implementation commit/tree and executable mutation plan.

## 3. Bounded proof (not authorized)

- [ ] 3.1 Verify exact pre-state, download and hash the immutable model snapshot, and start only the approved loopback services on the selected GPU.
- [ ] 3.2 Prove one `/v1/responses` request through Orchard scheduling/runtime to real generated text and capture existing request, model, latency, usage, event, and Console evidence.
- [ ] 3.3 Run the isolated short-repair and 131,072-rendered-input OpenCode smokes through Orchard, independently check the fixture, and prove overflow rejection without silent truncation.
- [ ] 3.4 Stop all proof processes; remove the model, credentials, database, containers, sockets, and temporary state; prove baseline restoration.
- [ ] 3.5 Obtain bounded review and record the honest KAP-112 disposition without a production or support claim.
