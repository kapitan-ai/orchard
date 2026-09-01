## 1. Contract Acceptance

- [x] 1.1 Inventory `NodeRuntimeService`, current consumers, supported compatibility profiles, configuration, packaging, tests, generated bindings, history, and bounded external-consumer evidence.
- [x] 1.2 Define the scoped deprecation boundary and preserve Peer Grant/control, Worker Runtime, Runtime Endpoint Interface, and future adapter extension-point boundaries.
- [x] 1.3 Define all-in-one, split-role, packaged, mixed-version, rollback, evidence, and four-layer deletion gates.
- [ ] 1.4 Obtain collaborator acceptance of this proposal.
- [ ] 1.5 Map future Bridge, Deprecation, Floor, and Removal epochs to exact released Product Versions and complete actual `N`, `N-1`, and reverse Controller rollback matrices only after their gates pass.

## 2. First Implementation Slice

- [ ] 2.1 Implement a same-VM transport-independent Runtime Endpoint client for all-in-one source development through public-seam TDD.
- [ ] 2.2 Make all-in-one `bin/dev` select the same-VM client by default while retaining explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` rollback.
- [ ] 2.3 Keep the Node Runtime listener, both runtime adapters, every protobuf source and generated binding, split-role behavior, packaged behavior, and shared dependencies unchanged.
- [ ] 2.4 Prove the all-in-one operation matrix with the real Node Agent and real MLX Worker Runtime, including status, load, streaming inference, active cancellation, prefix-cache scoring, unload, observation persistence, and no automatic gRPC fallback.
- [ ] 2.5 Prove an immediate restart into explicit gRPC compatibility mode and rerun the existing gRPC all-in-one smoke.
- [ ] 2.6 Reconcile `SPEC.md`, the accepted runtime-endpoints specification, ADR 0001, `docs/local-dev.md`, scripts, and focused tests in the implementing pull request.

### Copy-ready issue proposal

**Title:** Migrate all-in-one source development to the transport-independent Runtime Endpoint path

**Scope:**

- Add a same-VM Runtime Endpoint client for the all-in-one Controller and Node Agent that already run in one BEAM VM.
- Make all-in-one `bin/dev` use that client for its active first-party runtime path by default.
- Retain explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` selection as immediate rollback.
- Keep the Node Runtime gRPC listener enabled and keep both adapters, all generated bindings, split-role profiles, packaged profiles, Peer Grant/control, and Worker Runtime protocols unchanged.

**Acceptance criteria:**

- All-in-one `bin/dev` boots without requiring a Node Runtime gRPC loopback connection for its active first-party Runtime Endpoint path.
- The implementation uses the transport-independent Runtime Endpoint Interface and does not enable named distributed Erlang, EPMD, a cookie, or distribution listeners for same-VM calls.
- Status, model load and unload, real-MLX streaming inference, active cancellation, prefix-cache scoring, Runtime Endpoint observation persistence, activation, and liveness behavior pass through the same public seams as the current all-in-one path.
- No Runtime Endpoint request automatically falls back from the new path to gRPC.
- Explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` restarts the current all-in-one compatibility topology and passes its existing smoke.
- Split-role source development, packaged Controller and Node Agent releases, Orchard.app/DMG and launchd behavior, listener defaults, protobufs, generated bindings, dependencies, Peer Grant/control, and Worker Runtime behavior remain unchanged.
- `SPEC.md`, the accepted runtime-endpoints specification, ADR 0001, source-development documentation, and focused tests are reconciled in the same pull request.
- The full applicable Orchard Elixir workflow, all-in-one end-to-end smoke, strict OpenSpec validation, and architecture review pass at the exact head.

**Non-goals:**

- No split-role or packaged default change.
- No listener disablement or deprecation warning.
- No compatibility adapter, protobuf, generated binding, or dependency removal.
- No Peer Grant/control or Worker Runtime protocol change.
- No claim of packaged, physical multi-host, mixed-version, upgrade, or rollback qualification beyond the explicit gRPC restart proof in this slice.

**Validation:**

- Reproduce the existing all-in-one gRPC path before implementation.
- Add a failing public-seam test for the same-VM client before implementation.
- Run focused Runtime Endpoint, inference, scheduler, Node Agent, and configuration suites during iteration.
- Run the applicable full Elixir workflow from `AGENTS.md`.
- Run the real all-in-one MLX end-to-end smoke on the new path and the existing gRPC rollback smoke.
- Run strict validation for this OpenSpec change and the complete OpenSpec tree.

**Risk Assessment:** Medium.

- The blast radius is the primary all-in-one source-development inference topology.
- Immediate explicit gRPC rollback remains available and unchanged.
- The main risks are same-VM lifecycle divergence, accidental fallback, and observation or cancellation behavior drifting from the current Runtime Endpoint Interface.
- Real-MLX, public-seam, restart, and architecture-review evidence bound those risks.

## 3. Bridge Release

- [ ] 3.1 Qualify non-gRPC operation for every affected supported source-development and packaged profile, including real topology, real runtime, bootstrap, liveness, diagnostics, packaging, and rollback evidence.
- [ ] 3.2 Add a scoped operator warning for explicit `NodeRuntimeService` compatibility selection or listener enablement without warning about retained Peer Grant/control or Worker Runtime boundaries.
- [ ] 3.3 Publish and preserve the Bridge Release artifacts before any default-off or removal work begins.
- [ ] 3.4 Provide an operator reporting path for an unknown external `NodeRuntimeService` consumer and resolve any validated supported consumer before advancing.

## 4. Deprecation Release

- [ ] 4.1 Make the non-gRPC first-party path the only default for each qualified profile.
- [ ] 4.2 Make the Node Runtime listener default-off for qualified profiles and enable it only through the explicit compatibility profile.
- [ ] 4.3 Retain Controller and Node Agent compatibility adapters, runtime messages, generated bindings, and dependencies as rollback assets.
- [ ] 4.4 Prove Bridge and Deprecation mixed-version operation plus the reverse Controller rollback pairing.
- [ ] 4.5 Make upgrade preflight report gRPC-only configuration and missing non-gRPC capability, identity, authorization, and reachability before mutation.
- [ ] 4.6 Publish and preserve the Deprecation Release artifacts before raising the removal floor.

## 5. Floor Release And Compatibility Cutover

- [ ] 5.1 Ship a non-destructive Floor Release that retains the runtime listener, both runtime adapters, protocol bindings, and shared dependencies.
- [ ] 5.2 Enumerate the exact Product Versions in every compatibility epoch and prove every real Controller `N` with Node Agent `N` and `N-1` pairing through the Floor Release.
- [ ] 5.3 Add a durable compatibility cutover that records the exact Floor Product Version, capability contract, participating identities and versions, evidence time, and operator approval.
- [ ] 5.4 Reject the cutover unless every participating Controller and Node Agent already runs the Floor Release and proves non-gRPC removal readiness.
- [ ] 5.5 After cutover, reject update or rollback below the recorded Floor Release before mutation while all compatibility assets remain installed.

## 6. Removal Release

- [ ] 6.1 Require the previously recorded exact Floor Release cutover before an adapter-removal update begins and never create or raise that floor inside the Removal Release.
- [ ] 6.2 Prove Removal Controller with the immediately previous Floor Node Agent as the actual `N-1` pairing and Floor Controller with Removal Node Agent as the bounded Controller rollback pairing.
- [ ] 6.3 Remove the first-party Controller compatibility clients and mappers, Node Agent runtime server and listener, and compatibility-only callers and tests.
- [ ] 6.4 Reject retired runtime gRPC transport, target, listener, and credential configuration with a clear minimum-version error.
- [ ] 6.5 Preserve Peer Grant/control and Worker Runtime gRPC boundaries and their direct tests.

## 7. Runtime Protobuf Decoupling

- [ ] 7.1 Replace protobuf-shaped BEAM and domain internals with transport-independent Runtime Endpoint types before deleting any runtime message.
- [ ] 7.2 Migrate the provider-neutral Worker Runtime contract away from `cluster.v1.runtime` message imports through a separate accepted change with compatible generated bindings.
- [ ] 7.3 Remove `runtime.proto` and generated Elixir and Python runtime bindings only after no supported adapter, Worker Runtime, test, package, or generation task consumes them.
- [ ] 7.4 Preserve shared `common.proto`, `events.proto`, Peer Grant schemas, and shared dependencies wherever consumers remain.

## 8. Validation And Review

- [x] 8.1 Run `git diff --check` for this contract-only change.
- [x] 8.2 Run strict validation for `deprecate-node-runtime-grpc-compatibility` and strict validation for the complete OpenSpec tree.
- [x] 8.3 Obtain a pre-edit RepoPrompt architecture review plus Oracle sequencing challenge and incorporate blocker and important findings.
- [x] 8.4 Obtain a final diff-scoped RepoPrompt architecture review and resolve blocker or important findings.
- [x] 8.5 Confirm the proposal changes no runtime behavior, defaults, listeners, generated code, dependencies, or `SPEC.md` text.
