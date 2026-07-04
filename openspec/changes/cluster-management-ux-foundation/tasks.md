## 1. Contract Reconciliation

- [x] 1.1 Reconcile accepted cluster-management UX behavior back into `SPEC.md` without mirroring this OpenSpec package.
  Note: Reconciled accepted admission, Admin API dry-run preview, CLI admission-review command, Console admission-review, and shared freshness behavior from PRs #30 through #37.
  Reconciled node lifecycle transitions, lifecycle CLI commands, and preview-code stability from PRs #40 and #41.
  PR #42 required no `SPEC.md` change.
- [x] 1.2 Update `docs/DESIGN.md` only if Console node-management UI patterns introduce reusable tactical components.
  Note: Documented reusable operational review panel guidance for Action Preview panels, grouped node detail drill-ins, and source or compatibility badges.
- [x] 1.3 Update `docs/glossary/CONTEXT.md` if accepted terminology adds durable glossary entries such as pending admission, action preview, or scheduler reason code.
  Note: Added Pending Admission and Rejected Admission entries; existing entries already cover Runtime Endpoint Admission Candidate, Node Admission, Node Admission Decision, Action Preview, and reason-code terms.
- [x] 1.4 Add or update an ADR only if implementation chooses a durable architectural boundary not already fixed by `SPEC.md`.
  Note: Existing ADRs 0003, 0004, and 0005 cover observed candidates, Admin API cluster-admin auth, and shared cluster-management contracts; ADR 0006 records the local `orchardctl` node-admission authority boundary.

## 2. Node Lifecycle And Admission

- [x] 2.1 Change first-observed Runtime Endpoint node persistence so new nodes are not inserted as `active` without explicit admission.
- [x] 2.2 Add observed admission candidate persistence through `node_admission_candidates` for first-observed Runtime Endpoint observations that do not match an existing provisioned placeholder or registered node, including retention-safe snapshot fields for linked candidates, nullable observation timestamps for unobserved review rows, and non-unique target-reference lookup.
- [x] 2.3 Add reconciliation logic that prevents observed candidates from being represented as `provisioned` without an admin-created placeholder or as `registered` without `RegisterNode` or equivalent trust proof.
- [x] 2.4 Add pending-admission category handling without adding a lifecycle enum that is absent from `SPEC.md`.
- [x] 2.5 Preserve observed inventory, target metadata, and compatibility evidence for pending admission review.
- [x] 2.6 Block admission execution for observed candidates and provisioned placeholders until registration inventory, trust evidence, pool assignment, and required policy inputs are present.
- [x] 2.7 Implement and test rejected-admission persistence semantics through `node_admission_decisions` with actor, decided timestamp, reason, observed identity or node reference, target reference when applicable, retention-safe snapshot fields, and audit event reference.
- [x] 2.8 Implement Admin API admission and pending-admission rejection semantics with cluster-scoped audit events.
- [x] 2.9 Implement explicit admin clear or new-registration handling before re-admission after rejection.
- [x] 2.10 Preserve existing admitted node rows through migration or explicit compatibility handling.
- [x] 2.11 Add regression tests for `SPEC.md` §4.2, §4.3, and §7.5.4 lifecycle behavior.

## 3. Shared Status And Reason Codes

- [x] 3.1 Add shared domain structures for lifecycle, admission, freshness, transport, runtime readiness, compatibility, scheduling, warnings, and HA-lite read-only status.
- [x] 3.2 Add fixed scheduler explanation rejection codes and action preview blocker codes.
- [ ] 3.3 Ensure reason codes are used by Operator API, Admin API, CLI, Console, support bundles, and tests.
  Note: CLI/Admin admission previews now use shared `ActionPreview` blocker and confirmation codes.
  Console pending admission queue, detail drill-in, and admit/reject preview panels now render shared status, scheduler, blocker, warning, consequence, and confirmation codes for this slice.
  Admin API, CLI, Console, and tests consume the shared contract for landed admission-review behavior.
  Node lifecycle previews for cordon, uncordon, drain, maintenance, resume, and decommission now consume the shared blocker, consequence, and confirmation vocabulary across CLI and Console.
  Operator API, support bundles, and full scheduler-explanation producer wiring remain future slices.
- [x] 3.4 Add tests that reject unknown or free-text-only scheduler explanation reasons where fixed codes are required.
- [x] 3.5 Add shared JSON schema or golden fixtures for node status categories, action previews, scheduler explanations, and HA-lite status.
- [x] 3.6 Ensure action preview schema fixtures include separate `blockers`, `warnings`, `consequence_codes`, and `confirmation_requirements` fields.
- [x] 3.7 Add parity tests proving CLI JSON and Console data assigns derive from the same domain structures.

## 4. CLI Parity

- [x] 4.1 Implement `orchardctl nodes list --json` with separated status categories.
- [x] 4.2 Implement `orchardctl nodes inspect <node-id> --json`.
- [x] 4.3 Implement `orchardctl nodes pending` or an equivalent admission-review command.
- [x] 4.4 Implement `orchardctl nodes admit <node-id>` with dry-run and JSON preview support.
- [x] 4.5 Implement `orchardctl nodes reject <node-id|candidate-id>` with dry-run, JSON preview support, `--reason`, and required confirmation semantics aligned with Console and Admin API.
- [x] 4.6 Implement safe lifecycle commands for cordon, uncordon, drain, maintenance, resume, and decommission with dry-run, confirmation requirements, and JSON output.
  Note: this slice implements local `orchardctl nodes` lifecycle commands on the shared `ActionPreview` contract with transactional lifecycle state mutation, mutation-time revalidation, and cluster-scoped audit.
  Manual `draining -> maintenance` execution remains deferred: the `maintenance` command still exposes its dry-run preview but execution is blocked with a `drain_completion_unverified` blocker until drain completion (active-work quiescence) can be verified.
  Drain deadline orchestration, active-work cancellation, automatic `draining -> maintenance`, persisted lifecycle reason columns, decommission trust revocation, and Admin/Operator API lifecycle routes remain future work.
  Console lifecycle action preview panels are now implemented under task 5.3.
  Note: `SPEC.md` §11.9 now records the lifecycle commands and their preview and confirmation gates.
- [x] 4.7 Implement `orchardctl scheduler explain <request-id>` or reconcile with the existing `requests inspect` command if that is the repo-preferred path.
  Note: Implemented `orchardctl requests inspect <request-id>` because `SPEC.md` §11.9 names `requests inspect` as the required CLI path while `SPEC.md` §7.3.5 requires shared scheduler explanation reason codes across CLI and the Operator API.
  Note: The command uses local controller-runtime authority, reads the same request row as the Operator API, and renders human plus JSON output through `SchedulerExplanationPresenter` and the shared scheduler explanation contract.
  Note: Broader request execution diagnostics under `requests inspect` beyond persisted scheduler explanations remain future work, so the general command name is not fully delivered by this slice.
- [ ] 4.8 Implement `orchardctl cluster status --json` for read-only HA-lite and cluster summary status.

## 5. Console Nodes UX

- [x] 5.1 Add a pending admission queue to the Console Nodes workspace.
- [x] 5.2 Add node detail drill-in that preserves separate lifecycle, health, freshness, transport, runtime, compatibility, scheduling, and warning groups.
- [x] 5.3 Add action preview dialogs or page-local panels for admit, reject pending admission, cordon, uncordon, drain, maintenance, resume, and decommission.
  Note: this slice implements Console admit and reject pending admission preview panels using the shared `ActionPreview` contract.
  Reusable Console review-panel guidance is now documented in `docs/DESIGN.md`.
  Console node detail now exposes lifecycle action preview panels for cordon, uncordon, drain, maintenance, resume, and decommission using the shared `ActionPreview` contract.
  Existing backend execution is wired for cordon, uncordon, drain, resume, and decommission with confirmation gates and mutation-time lifecycle revalidation.
  Maintenance remains preview-visible but execution-blocked by `drain_completion_unverified` until drain completion and active-work quiescence can be verified.
  Drain deadline orchestration, active-work cancellation, automatic `draining -> maintenance`, known active request counts, and any reusable dialog primitive remain future slices.
- [ ] 5.4 Add scheduler explanation views with selected candidate, skipped candidates, fixed reason codes, and sanitized diagnostics.
- [ ] 5.5 Add diagnostics and support bundle entry points that use the shared support bundle contract.
- [ ] 5.6 Add read-only HA-lite control-plane status.
- [ ] 5.7 Verify Console UI against `docs/DESIGN.md` and `docs/brand-identity.md` with browser screenshots during implementation.
  Note: PR #37 browser-verified the admission-review slice against `docs/DESIGN.md` and brand identity on desktop and mobile.
  PR #41 browser-verified the Console lifecycle preview slice against `docs/DESIGN.md`.
  Keep this unchecked as a recurring gate for future Console slices.

## 6. Diagnostics And Support Bundles

- [ ] 6.1 Align Console-triggered support bundles with the archive format emitted by `orchardctl support bundle create`.
- [ ] 6.2 Upgrade `orchardctl support bundle create` to emit `orchard.support_bundle.v2` for cluster-management support bundles.
- [ ] 6.3 Make Console-triggered bundles use the same v2 archive format.
- [ ] 6.4 Document any v1 compatibility behavior separately; v2 fields required by this change are mandatory for the new contract.
- [ ] 6.5 Add scope selection for cluster, node, request, scheduler decision, runtime endpoint, control plane, and HA-lite evidence.
- [ ] 6.6 Add a redaction manifest with redaction classes and counts.
- [ ] 6.7 Ensure support bundles exclude plaintext secrets, credentials, DSNs, prompt bodies, response bodies, raw token sequences, raw local evidence logs, and tool session identifiers.
- [ ] 6.8 Add tests for support bundle manifest contents and redaction behavior.
- [ ] 6.9 Add tests proving request and scheduler-decision scoped bundles include sanitized metadata only.

## 7. Scheduler Explanations

- [x] 7.1 Persist scheduler explanations using stable reason-code arrays.
  Note: `Requests.record_schedule/2` now validates scheduler explanation maps against the shared fixed reason-code contract before persisting them.
- [x] 7.2 Expose `GET /ops/v1/scheduler/explanations/:request_id` with the accepted reason-code vocabulary.
  Note: The Operator API route now returns persisted scheduler explanations through the shared `SchedulerExplanation` presenter and cluster operator or admin service-account authorization.
  Future slice note: `SPEC.md §7.3.5` defines the not-found code for absent requests but is silent on legacy scheduler decisions without candidate keys, so the endpoint currently keeps returning an empty explanation shape for those rows.
- [x] 7.3 Ensure queue-waitable outcomes preserve whether the reason was live node capacity, requested model path capacity, placement capacity, or tenant active capacity.
  Note: Queue admission and post-grant requeue metadata now preserve stable `queue_wait_reason` values for tenant active capacity, requested model path capacity, live node capacity, and explicit placement capacity.
  Future slice note: Placement-capacity queue-wait emission remains incomplete end to end until the orchestrator busy return can carry a placement-specific scheduler reason.
- [x] 7.4 Add tests that explanations match actual scheduler decisions.
  Note: `MultiNode.schedule/2` tests now assert the generated explanation validates against the shared contract and matches selected, rejected, and skipped scheduler decisions.
- [x] 7.5 Add `skipped_candidates` explanation output with stable skip codes and keep skipped candidates outside the rejected-candidate list.
  Note: Multi-node scheduling now emits lower-tier candidates in `skipped_candidates` with `lower_tier_not_considered` instead of reporting them as rejected.
- [x] 7.6 Add tests for selected, rejected, and skipped candidate explanation shapes.
  Note: Scheduler tests now cover selected scored candidates, capacity rejected candidates, and skipped lower-tier candidates through the public `MultiNode.schedule/2` API.

## 8. Validation

- [x] 8.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate cluster-management-ux-foundation --type change --strict --no-interactive`.
  Note: Re-run for this docs reconciliation slice; future implementation slices and archive handoff must rerun this gate.
- [ ] 8.2 For implementation slices, run `mise exec -- mix format`.
- [ ] 8.3 For implementation slices, run `mise exec -- mix compile --warnings-as-errors`.
- [ ] 8.4 For implementation slices, run `mise exec -- mix credo --strict`.
- [ ] 8.5 For implementation slices, run `mise exec -- mix dialyzer`.
- [ ] 8.6 For implementation slices, run `mise exec -- mix test`.
- [ ] 8.7 For implementation slices, run `mise exec -- mix test --cover`.
  Note: These implementation gates remain unchecked for future product-code slices; this reconciliation changes docs and the normative contract only.
