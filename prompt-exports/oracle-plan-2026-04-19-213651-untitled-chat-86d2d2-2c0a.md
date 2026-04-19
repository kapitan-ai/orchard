# Oracle Plan

## 1. Summary

Reach would be most valuable for Orchard as a **query-driven OTP/data-flow analysis tool**, not as a broad “turn it on and trust it” quality gate. The selected Orchard files contain exactly the kind of code Reach is designed to illuminate: GenServer state threading, async task ownership, monitor/`DOWN` handling, timeout messages, cancellation paths, terminal event propagation, and cross-process request lifecycle edges. The highest-value first target is `Orchard.Node.ModelManager`, followed by the request execution path spanning `RequestOrchestrator` → `RequestDispatcher` → `WorkerProcess`. Adoption should start as a **dev/test-only dependency on a short-lived evaluation branch**, with local/manual runs and no CI gating until reports are triaged and noise from generated protobuf, Phoenix/Ecto, and dynamic runtime seams is understood.

---

## 2. Current-state analysis

### Existing robustness stack

Orchard already has a strong conventional safety net:

- Extensive module-level tests exist for the selected areas:
  - `model_hub_download_coordinator_test.exs`
  - `request_orchestrator_test.exs`
  - `dispatch_test.exs`, `cold_start_benchmark_test.exs`
  - `worker_process_test.exs`
  - likely coverage around model loading, cancellation, and request persistence.
- Runtime observability is present:
  - `RequestDispatcher` emits `dispatch_timing` logs.
  - `ModelManager` emits telemetry for model load and eviction.
  - `WorkerProcess` forwards worker port logs with metadata.
- Static/style tools exist:
  - Credo.
  - ExDNA.
  - Manual review.

The gap is that the most failure-prone logic is not local expression-level logic; it is **multi-process control flow** with dynamic state maps, task messages, monitors, callbacks, and timeout races. Tests can cover important scenarios, but the interleaving space is large.

Reach would improve robustness specifically where Orchard’s behavior depends on “does this message/state edge actually connect to the expected cleanup/finalization path?”

---

## 3. Where Reach would materially improve robustness

### A. `Orchard.Node.ModelManager`: model-load lifecycle, waiter deadlines, and worker ownership

`apps/orchard_node_agent/lib/orchard/node/model_manager.ex`

This is the strongest fit.

#### Current responsibilities

`ModelManager` owns:

- Loaded model workers:
  - `workers`
  - `worker_refs`
- Active inference requests:
  - `active_requests`
  - `subscriber_refs`
- In-flight model loads:
  - `inflight_loads`
  - `load_refs`
- Async model acquisition/load tasks under `Orchard.Node.ModelLoadTaskSupervisor`.
- Worker processes under `WorkerSupervisor`.
- Deadline timers for individual load waiters.
- Monitor handling for:
  - load tasks,
  - worker processes,
  - subscribers.

#### Current data/control flow

For `ensure_model_loaded/1`:

```text
controller/node runtime RPC
  → ModelManager.ensure_model_loaded/1
  → GenServer.call {:ensure_model_loaded, request}
  → fast path if worker already loaded
  → join existing inflight load OR start new task
  → Task.Supervisor.async_nolink(...)
  → run_load_pipeline/4
  → AcquisitionRequest.from_proto/2
  → ModelAcquisition.ensure_cached/1
  → WorkerSupervisor.start_worker/2
  → send manager {:model_load_worker_started, key, task_pid, worker_pid}
  → WorkerProcess.ensure_loaded/3
  → send manager {:model_load_finished, key, task_pid, result}
  → complete_inflight_load/4
  → reply waiters
  → promote worker to LOADED or clean it up
```

For cancellation/deadlines:

```text
waiter timer
  → {:inflight_waiter_timeout, key, task_ref, waiter_id}
  → handle_waiter_expiry/3
  → possibly abort task
  → possibly restart task with surviving waiters
  → possibly cleanup partial worker

unload/reset
  → cancel_inflight_load/3
  → terminate task
  → drain_pending_worker_started/3
  → cleanup_failed_worker/2
  → reply waiters
```

For inference request ownership:

```text
prepare_request/2
  → stores active request
  → monitors subscriber

start_request/1
  → WorkerProcess.start_request/4

subscriber DOWN
  → maybe_cancel_orphaned_request/2

worker finished
  → {:worker_request_finished, worker_pid, request_id}
  → remove active request
```

#### What Reach adds beyond tests/logs

Reach’s OTP-aware edges should help answer questions that are currently manual:

- Which code paths can create a `worker_pid`, and which paths can remove or orphan it?
- Do all paths that remove an inflight load also remove the matching `load_refs` entry?
- Which messages can arrive after task cancellation, and which handlers ignore or clean them?
- Which paths reply to GenServer callers via `GenServer.reply/2` instead of returning directly?
- Which paths can leave waiters unreplied?
- Which paths can leave `subscriber_refs` or `worker_refs` stale?
- What is the impact of changing `EnsureModelLoadedRequest.deadline_unix_ms`, `artifact_source_uri`, or `preload`?
- What is the impact of changing `WorkerProcess.ensure_loaded/3`, `WorkerProcess.status/2`, or `WorkerSupervisor.start_worker/2`?

This is better than log review because logs only show executed scenarios. It is better than Credo/ExDNA because the risks are not primarily style or local complexity; they are OTP lifecycle reachability and cleanup consistency.

---

### B. `Orchard.Dispatch.RequestDispatcher`: cancellation, terminal events, and transport failure handling

`apps/orchard_controller/lib/orchard/dispatch/request_dispatcher.ex`

#### Current responsibilities

`RequestDispatcher` owns a single dispatch attempt:

```text
schedule
  → connect to node runtime
  → status probe
  → ensure_model_loaded
  → execute_inference
  → receive stream events
  → cancel on timeout / caller DOWN / event handler :cancel
  → synthesize terminal event if needed
  → emit timing log
```

It handles messages from the runtime client:

- `{:dispatch_event, task_ref, request_id, event}`
- `{:dispatch_done, task_ref, result}`
- `{:dispatch_timeout, timer_ref}`
- `{:DOWN, caller_ref, :process, _pid, _reason}`

It also performs side effects:

- `client.cancel_inference/2`
- `Orchard.Nodes.record_transport_failure/3`
- `Orchard.Nodes.observe_status/3`
- optional `on_node_resolved` callback
- event handler invocation

#### What Reach adds

Reach is useful here for validating the shape of cancellation and terminal handling:

- From each cancellation trigger, does control flow reach `client.cancel_inference/2`?
  - timeout,
  - caller process exit,
  - event handler returning `:cancel`.
- After cancellation, does control flow reach either:
  - a real terminal event, or
  - a synthesized `InferenceEvent.failed/3`?
- Which paths return `{:error, {:dispatch_failed, reason}}` before any event is emitted?
- Which paths return `{:ok, events}` with non-terminal event lists?
- Which transport failures reach `mark_transport_failure/2`?
- What depends on `InferenceEvent.terminal?/1`?
- What depends on `InferenceEvent.OutputTextDelta` versus `Completed`/`Failed`?

These questions are hard to answer conclusively by inspection because the receive loop and drain loop are split across several helpers.

Reach would not prove timing correctness, but it can reduce review risk when changing cancellation or event semantics.

---

### C. `Orchard.Inference.RequestOrchestrator`: durable request lifecycle and terminal persistence

`apps/orchard_controller/lib/orchard/inference/request_orchestrator.ex`

#### Current responsibilities

`RequestOrchestrator` is the durable lifecycle owner for canonical inference requests:

```text
CanonicalRequest
  → validate resolved tooling
  → serialize canonical request
  → create DB request
  → start RequestServer FSM
  → advance FSM through validated/scheduled/dispatching
  → build ExecuteInferenceRequest
  → build EnsureModelLoadedRequest
  → RequestDispatcher.dispatch/4
  → collect events and first token timestamp
  → build terminal attrs
  → append step events
  → persist terminal request state
```

It also handles:

- idempotency replay/conflict,
- request step events,
- tool-call proposal reconstruction,
- non-stream success persistence,
- failure persistence through `ChatError`,
- node assignment via `on_node_resolved`.

#### Current mutation points

Important side effects include:

- `Requests.create_request/1`
- `RequestServer.start/1`
- `RequestServer.transition/2`
- `Requests.record_schedule/2`
- `Requests.assign_node/2`
- `Requests.append_request_step_events/2`
- `Requests.mark_terminal_with_step_events/3`

#### What Reach adds

Reach is useful for impact and slice analysis around “does every persisted request reach a terminal persistence path?”

Concrete questions Reach can help answer:

- For every path after `Requests.create_request/1` succeeds, what paths can skip `terminal_persister`?
- Which errors are persisted through `fail_request/4`, and which are returned before persistence?
- What is the impact of changing `RequestDispatcher.dispatch/4`’s return shape?
- What depends on `InferenceEvent.kind/1`, `InferenceEvent.terminal?/1`, and `Completed.usage`?
- What data from `CanonicalRequest.Tooling` reaches:
  - `GenerationParams.tools_json`,
  - `GenerationParams.tool_choice_json`,
  - step-event proposal records,
  - terminal step results?
- What is the impact of changing tool-call finish reasons or tool-call accumulator output shape?
- What depends on the process-dictionary first-token capture?

This module is less OTP-message-heavy than `ModelManager`, but it is very important because mistakes here affect persisted request correctness and API-visible terminal states.

---

### D. `Orchard.Node.WorkerProcess`: adapter boundary and request completion

`apps/orchard_node_agent/lib/orchard/node/worker_process.ex`

#### Current responsibilities

`WorkerProcess` owns the per-model runtime adapter state:

```text
WorkerSupervisor.start_worker
  → WorkerProcess.init
  → RuntimeAdapter.impl()
  → adapter.load_model
  → adapter.start_generation
  → receive {:runtime_adapter_event, generation_ref, event}
  → send subscriber {:node_runtime_event, request_id, event}
  → if terminal:
        finish_generation
        notify ModelManager {:worker_request_finished, self(), request_id}
```

It also handles:

- adapter completion without terminal event,
- cancellation,
- unload,
- port log forwarding,
- runtime port/gun shutdown,
- adapter cleanup in `terminate/2`.

#### What Reach adds

Reach can help trace:

- adapter events to subscriber messages,
- terminal events to `ModelManager` cleanup notification,
- `runtime_adapter_done` to synthesized failure event,
- unload/cancel paths to adapter cleanup,
- impact of changing `RuntimeAdapter` callback return shapes.

This should usually be analyzed together with `ModelManager`; the important correctness property crosses the module boundary.

---

### E. `OrchardConsole.ModelHubDownloadCoordinator`: smaller calibration target

`apps/orchard_controller/lib/orchard/console/model_hub_download_coordinator.ex`

This is a good early “calibration” target because it is a bounded GenServer with clear state and message flow.

#### Current responsibilities

It owns model-hub download/import lifecycle snapshots:

```text
ModelHubLive or other caller
  → start_download(repo_id, opts)
  → GenServer.call {:start_download, repo_id, opts}
  → start_download_import(self(), ref, repo_id, seam_opts)
  → monitor task pid
  → receive {:model_hub, ref, ...}
  → normalize progress
  → update snapshot
  → PubSub broadcast {:model_hub_download, snapshot}
  → receive :DOWN
  → terminal error if task died before terminal message
```

State maps:

- `jobs_by_ref`
- `active_ref_by_repo`
- `latest_ref`
- `latest_ref_by_repo`
- `monitor_ref_to_job_ref`

#### What Reach adds

Reach can help verify:

- all `:model_hub` message variants reach snapshot update or are ignored as stale,
- `:DOWN` and `:download_finished` both clean up active/monitor state,
- terminal snapshots stop accepting progress,
- impact of adding a new status/phase,
- whether dedup by `repo_id` conflicts with snapshot key `{repo_id, requested_revision}`.

This is not as critical as `ModelManager`, but it is a low-risk first experiment.

---

## 4. Best first targets

### Target 1 — `Orchard.Node.ModelManager`

**Why first:** highest concurrency complexity, highest resource-leak risk, strongest match to Reach’s OTP-aware graph model.

Focus areas:

- `ensure_model_loaded/1`
- `handle_inflight_join/4`
- `start_load_task/4`
- `run_load_pipeline/4`
- `complete_inflight_load/4`
- `handle_waiter_expiry/3`
- `abort_inflight_attempt/4`
- `restart_inflight_load/4`
- `cancel_inflight_load/3`
- `drain_pending_worker_started/3`
- `handle_info/2` for:
  - `:model_load_worker_started`
  - `:model_load_finished`
  - task `{ref, result}`
  - waiter timeout
  - `:DOWN`
  - `:worker_request_finished`

Key questions:

- Can an inflight load be removed without replying all waiters?
- Can a worker be started but never tracked or terminated?
- Can `load_refs`/`worker_refs`/`subscriber_refs` retain stale monitor refs?
- Can an active request remain after subscriber death, worker death, unload, or force unload?
- What happens to capacity accounting if a worker is in `:PLACEMENT_STATE_LOADING` and the task crashes?

---

### Target 2 — `ModelManager` + `WorkerProcess` pair

**Why second:** the correctness boundary is cross-process.

Focus areas:

- `ModelManager.prepare_request/2`
- `ModelManager.start_request/1`
- `ModelManager.cancel_request/2`
- `WorkerProcess.start_request/4`
- `WorkerProcess.handle_info({:runtime_adapter_event, ...})`
- `WorkerProcess.handle_info({:runtime_adapter_done, ...})`
- `WorkerProcess.finish_generation/3`
- `WorkerProcess.notify_request_finished/2`

Key questions:

- Does every terminal runtime event notify the subscriber and then notify `ModelManager`?
- Does `runtime_adapter_done` without terminal event synthesize a failed event and clean up?
- Can cancellation leave the request in `WorkerProcess.requests`?
- Can `ModelManager.active_requests` and `WorkerProcess.requests` diverge permanently?

---

### Target 3 — `RequestOrchestrator` + `RequestDispatcher`

**Why third:** this is the user-visible inference lifecycle and persistence path.

Focus areas:

- `RequestOrchestrator.execute/3`
- `run_dispatch_pipeline/8`
- `dispatch/6`
- `finalize/9`
- `fail_request/4`
- `terminal_attrs_from_events/1`
- `RequestDispatcher.dispatch/4`
- `receive_loop/2`
- `drain_until_terminal_or_done/3`

Key questions:

- After a DB request is created, which error paths do not call `terminal_persister`?
- Which dispatch failures become durable failed requests?
- Which cancellation paths synthesize terminal events?
- What is the impact of changing `InferenceEvent.terminal?/1`?
- What is the impact of changing `RequestDispatcher.dispatch/4` return types?
- Does first-token capture observe all non-empty `OutputTextDelta` events before terminal persistence?

---

### Target 4 — `ModelHubDownloadCoordinator`

**Why fourth or as a warm-up:** smaller GenServer, easy to compare Reach output against known behavior.

Focus areas:

- `start_download/2`
- `handle_info/2` for model-hub seam messages
- `cleanup_monitor/2`
- `cleanup_all_jobs/1`
- `update_job_snapshot/3`

Key questions:

- Are all terminal paths broadcasting exactly one terminal snapshot?
- Can a `:DOWN` after `:download_finished` create duplicate terminal state?
- Can progress after terminal mutate a completed/error snapshot?
- Is deduplication by `repo_id` intentional even when `requested_revision` differs?

---

## 5. What Reach would likely miss or fail to prove

### A. It will not prove temporal concurrency correctness

Reach can show that edges exist, but it should not be treated as a model checker.

It likely will not prove:

- absence of all race conditions,
- exact ordering of stale messages after task cancellation,
- correctness of `Process.send_after/3` timer timing,
- that `Process.cancel_timer/1` always prevents timeout handling,
- that `drain_pending_worker_started/3` catches every orphan-worker race,
- that waiter deadlines are fair or optimal,
- that every possible BEAM scheduling interleaving is safe.

For example, in `ModelManager`, Reach can show that `abort_inflight_attempt/4` calls `drain_pending_worker_started/3` and `cleanup_failed_worker/2`, but it cannot fully prove that no worker-start message can arrive immediately after the zero-timeout drain.

---

### B. Dynamic implementation seams will reduce precision

Several important dependencies are selected dynamically:

- `RuntimeAdapter.impl()` in `WorkerProcess`.
- `Node.worker_backend()`.
- `Inference.scheduler()` in `RequestOrchestrator`.
- `model_hub_impl()` in `ModelHubDownloadCoordinator`.
- `client_impl` option in `RequestDispatcher`.
- `success_persistence`, `event_handler`, `step_event_appender`, and `terminal_persister` callbacks in `RequestOrchestrator`.

Reach may under-approximate or over-approximate these unless configured with concrete modules or analyzed with test seams.

Do not assume a clean graph means the dynamic callback implementation is safe.

---

### C. External systems are outside the proof boundary

Reach will not prove correctness of:

- gRPC transport behavior,
- Python MLX worker behavior,
- model artifact acquisition from Hugging Face/S3/file sources,
- port/gun lifecycle correctness beyond Elixir message handling,
- Ecto database constraints,
- transaction isolation,
- Phoenix PubSub delivery,
- LiveView subscription behavior,
- OS process cleanup,
- filesystem cleanup.

For example, `WorkerProcess.terminate/2` calls `adapter.unload_model/2`. Reach can show the call exists, but not that the Python worker process exits, the socket is removed, or the model memory is freed.

---

### D. Map invariants with dynamic keys are hard to prove

The selected modules use dynamic maps heavily:

- `jobs_by_ref`
- `active_ref_by_repo`
- `monitor_ref_to_job_ref`
- `workers`
- `worker_refs`
- `active_requests`
- `subscriber_refs`
- `inflight_loads`
- `load_refs`

Reach can trace updates, but it likely cannot prove invariants such as:

```text
every worker_refs entry has a corresponding workers entry
every active_request subscriber monitor is present in subscriber_refs
every inflight load has a matching load_refs entry
every terminal job is absent from active_ref_by_repo
```

Those invariants still need tests or explicit runtime assertions if the team wants stronger guarantees.

---

### E. Generated protobuf and macro-heavy code may create noise

The repository includes generated protobuf modules:

- `apps/orchard_shared/lib/cluster/v1/*.pb.ex`
- `apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex`

Reach dead-code or impact reports may flag generated functions or protocol structs that are only used reflectively or externally. These should be excluded or triaged separately.

Phoenix/Ecto macros can also make reachability less obvious than ordinary Elixir functions.

---

### F. Dead-code findings may be false positives for public APIs

Some functions are externally invoked by:

- GenServer names,
- supervisors,
- mix tasks,
- Phoenix routes/controllers,
- tests,
- release scripts,
- generated RPC dispatch,
- external clients.

A `reach.dead_code` finding should mean “not reached under this analysis root,” not automatically “safe to delete.”

---

## 6. Recommended minimal adoption plan

### Recommendation

Start with a **temporary dev/test-only dependency on an evaluation branch**, not a production dependency and not a CI gate.

Reasoning:

- Reach’s value depends on how well it understands this umbrella project and OTP code.
- The team needs to measure report quality before adding CI noise.
- Mix tasks are easier and more reproducible as a dev/test dependency than as an ad hoc one-off script.
- Runtime code should not depend on Reach.

Suggested dependency posture:

```elixir
# root mix.exs if umbrella-level deps are supported,
# otherwise only in apps/orchard_node_agent and apps/orchard_controller during the spike.
{:reach, github: "dannote/reach", only: [:dev, :test], runtime: false}
```

Do not ship it in prod releases.

---

### Phase 0 — Local spike only

Run on a short-lived branch.

Baseline first:

```sh
MIX_ENV=test mix compile
MIX_ENV=test mix test apps/orchard_node_agent/test/orchard/node/worker_process_test.exs
MIX_ENV=test mix test apps/orchard_controller/test/orchard/inference/request_orchestrator_test.exs
```

Then run Reach against the smallest bounded target:

```sh
MIX_ENV=test mix reach.otp OrchardConsole.ModelHubDownloadCoordinator
MIX_ENV=test mix reach.slice OrchardConsole.ModelHubDownloadCoordinator.start_download/2
MIX_ENV=test mix reach.impact OrchardConsole.ModelHubDownloadCoordinator
```

Purpose:

- Confirm Reach can parse the umbrella.
- Confirm OTP message output is understandable.
- Establish how much generated/macro noise appears.

Success criteria:

- Reach output identifies the GenServer callbacks and message paths in a way that matches the known coordinator lifecycle.
- False positives are understandable and documentable.
- The team can answer at least one lifecycle question faster than by manual review.

---

### Phase 1 — High-value OTP target: `ModelManager`

Run OTP and slice analysis around model loading:

```sh
MIX_ENV=test mix reach.otp Orchard.Node.ModelManager
MIX_ENV=test mix reach.slice Orchard.Node.ModelManager.ensure_model_loaded/1
MIX_ENV=test mix reach.slice Orchard.Node.ModelManager.handle_info/2
MIX_ENV=test mix reach.impact Orchard.Node.ModelManager
MIX_ENV=test mix reach.smell Orchard.Node.ModelManager
```

If Reach supports MFA-to-MFA flow selectors, use queries equivalent to:

```sh
MIX_ENV=test mix reach.flow \
  Orchard.Node.ModelManager.ensure_model_loaded/1 \
  Orchard.Node.WorkerProcess.ensure_loaded/3

MIX_ENV=test mix reach.flow \
  Orchard.Node.ModelManager.cancel_request/2 \
  Orchard.Node.WorkerProcess.cancel_request/2

MIX_ENV=test mix reach.flow \
  Orchard.Node.ModelManager.unload_model/1 \
  Orchard.Node.WorkerProcess.unload/2
```

Important: exact selector syntax should be validated against Reach’s README, but the intended queries are these MFA boundaries.

Triage findings into:

1. real bug,
2. design risk worth testing,
3. acceptable dynamic behavior,
4. generated/framework noise.

Success criteria:

- A reviewer can use the Reach output to explain:
  - task start/completion message paths,
  - waiter timeout paths,
  - worker monitor cleanup,
  - subscriber monitor cleanup.
- No high-confidence orphan-worker or unreplied-waiter path remains unexplained.
- Any noisy generated-code findings can be excluded or ignored consistently.

---

### Phase 2 — Cross-process request execution path

Run Reach over `ModelManager` and `WorkerProcess` together:

```sh
MIX_ENV=test mix reach.otp Orchard.Node.ModelManager Orchard.Node.WorkerProcess
MIX_ENV=test mix reach.flow \
  Orchard.Node.WorkerProcess.handle_info/2 \
  Orchard.Node.ModelManager.handle_info/2
```

Queries to answer manually from the graph:

- Does `{:runtime_adapter_event, generation_ref, terminal_event}` reach:
  - subscriber notification,
  - `finish_generation/3`,
  - `notify_request_finished/2`,
  - `ModelManager.handle_info({:worker_request_finished, ...})`?
- Does `{:runtime_adapter_done, generation_ref}` synthesize a failed terminal event?
- Which paths remove `WorkerProcess.requests`?
- Which paths remove `ModelManager.active_requests`?

Success criteria:

- Terminal event cleanup is visible end-to-end.
- Any divergence between `WorkerProcess.requests` and `ModelManager.active_requests` is either impossible by design or covered by tests.

---

### Phase 3 — Durable request lifecycle

Run Reach over controller-side orchestration:

```sh
MIX_ENV=test mix reach.otp Orchard.Dispatch.RequestDispatcher
MIX_ENV=test mix reach.slice Orchard.Inference.RequestOrchestrator.execute/3
MIX_ENV=test mix reach.slice Orchard.Dispatch.RequestDispatcher.dispatch/4
MIX_ENV=test mix reach.impact Orchard.InferenceEvent
MIX_ENV=test mix reach.impact Orchard.Dispatch.RequestDispatcher
```

If supported, use flow queries equivalent to:

```sh
MIX_ENV=test mix reach.flow \
  Orchard.Inference.RequestOrchestrator.execute/3 \
  Orchard.Requests.mark_terminal_with_step_events/3

MIX_ENV=test mix reach.flow \
  Orchard.Dispatch.RequestDispatcher.dispatch/4 \
  Orchard.Dispatch.GrpcNodeRuntimeClient.cancel_inference/2
```

Questions to answer:

- After `Requests.create_request/1` succeeds, which paths skip terminal persistence?
- Which dispatch errors are converted through `ChatError` and persisted?
- Which cancellation paths produce terminal `InferenceEvent.failed/3` events?
- What changes if `InferenceEvent.terminal?/1` semantics change?

Success criteria:

- All non-replay persisted request paths have a documented terminal persistence path or a deliberate exception.
- Cancellation behavior is traceable from timeout/disconnect to cancel RPC and synthesized terminal event.
- Impact of `InferenceEvent` changes is clear before modifying event structs.

---

### Phase 4 — Dead code and smell scans, scoped and non-blocking

Run only after the targeted graph output is understood:

```sh
MIX_ENV=test mix reach.dead_code
MIX_ENV=test mix reach.smell
```

Scope or exclude generated protobuf and test support if Reach supports exclusions.

Recommended exclusions:

```text
Cluster.V1.*
*.pb.ex
test/support/*
generated protobuf modules
```

Success criteria:

- No selected production module has unexplained high-confidence dead code.
- Any dead-code candidate has an owner decision:
  - delete,
  - keep public API,
  - keep test seam,
  - ignore generated code,
  - add explicit test/reference.

---

## 7. CI recommendation

### Initial recommendation: no required CI gate

Do **not** add Reach as a required CI check initially.

Reasons:

- Static graph tools often produce useful but noisy reports early.
- Generated protobuf, Phoenix/Ecto macros, dynamic callback seams, and umbrella boundaries may need configuration.
- A red CI gate before triage would train people to ignore or bypass the tool.

### Better initial workflow

Use Reach manually for changes touching:

- `ModelManager`
- `WorkerProcess`
- `RequestDispatcher`
- `RequestOrchestrator`
- `ModelHubDownloadCoordinator`
- `InferenceEvent`
- request cancellation semantics
- model-load timeout semantics
- terminal persistence semantics

Add a short checklist item to `docs/code-quality.md` or PR guidance:

```text
For changes to OTP lifecycle modules, run the relevant Reach slice/otp query and include any non-obvious lifecycle impact in the PR description.
```

### Later optional CI

After 2–3 real PRs use it successfully, add a non-blocking or scheduled CI job for:

```sh
MIX_ENV=test mix reach.dead_code
MIX_ENV=test mix reach.smell
```

Keep `reach.otp`, `reach.flow`, and `reach.slice` as reviewer/developer tools rather than broad CI checks unless Reach supports stable, scoped, machine-readable assertions.

---

## 8. File-by-file impact for minimal adoption

### `mix.exs` at umbrella root

**Change:** Add Reach as a dev/test-only dependency if the umbrella root manages shared deps.

**Why:** Makes the mix tasks reproducible for both controller and node-agent analysis.

**Dependency:** None.

**Risk:** Could affect dependency resolution. Keep on an evaluation branch first.

---

### `apps/orchard_node_agent/mix.exs`

**Change:** Only add Reach here if umbrella-level dependency is not practical.

**Why:** Needed for `ModelManager` and `WorkerProcess` analysis.

**Dependency:** Prefer root-level dependency first.

---

### `apps/orchard_controller/mix.exs`

**Change:** Only add Reach here if umbrella-level dependency is not practical.

**Why:** Needed for `RequestDispatcher`, `RequestOrchestrator`, and `ModelHubDownloadCoordinator` analysis.

**Dependency:** Prefer root-level dependency first.

---

### `docs/code-quality.md`

**Change:** Add a short “Reach usage” section after the evaluation succeeds.

Include:

- when to run Reach,
- which modules are high-value targets,
- which commands to run,
- how to treat dead-code findings,
- exclusions/noise notes for protobuf and dynamic seams.

**Why:** Prevents Reach from becoming tribal knowledge.

---

### No production module changes initially

Do **not** modify:

- `ModelManager`
- `WorkerProcess`
- `RequestDispatcher`
- `RequestOrchestrator`
- `ModelHubDownloadCoordinator`

during initial adoption unless Reach finds a concrete issue.

Reach should first be used to understand and validate existing lifecycle assumptions.

---

## 9. Architectural risks and false confidence traps

### Trap 1 — Treating reachability as correctness

A path existing in the graph does not mean the runtime interleaving is safe.

Example:

```text
abort_inflight_attempt/4
  → drain_pending_worker_started/3
  → cleanup_failed_worker/2
```

Reach can show the cleanup path exists. It cannot fully prove that no worker-start message can arrive immediately after the zero-timeout drain.

---

### Trap 2 — Ignoring dynamic module seams

Important behavior is injected dynamically:

```elixir
RuntimeAdapter.impl()
Inference.scheduler()
model_hub_impl()
client_impl
event_handler
terminal_persister
success_persistence
```

A clean graph over the default module does not prove alternate test/prod implementations are safe.

---

### Trap 3 — Overreacting to dead-code reports

Public functions such as GenServer APIs, Phoenix callbacks, mix task entry points, generated protobuf functions, and externally called RPC handlers may appear dead depending on the analysis root.

Dead code must be triaged, not blindly deleted.

---

### Trap 4 — Letting the tool reshape good OTP design

Do not flatten callbacks, remove dynamic seams, or avoid message passing just to make graphs prettier. Orchard’s OTP boundaries are intentional:

- `ModelManager` owns model state.
- `WorkerProcess` owns adapter state.
- `RequestDispatcher` owns one dispatch attempt.
- `RequestOrchestrator` owns durable request lifecycle.

Reach should document and validate those boundaries, not pressure the codebase toward a worse architecture.

---

### Trap 5 — Missing persistence correctness

Reach can trace calls to `Requests.mark_terminal_with_step_events/3`, but it will not prove:

- Ecto constraints,
- idempotency uniqueness,
- transaction semantics,
- database rollback behavior,
- schema migration compatibility.

Persistence-heavy paths still need database tests.

---

### Trap 6 — Missing external runtime behavior

The MLX worker, Python process, gRPC transport, filesystem acquisition, Hugging Face/S3 downloads, and OS process lifecycle remain outside Reach’s meaningful proof boundary.

For those, keep:

- integration tests,
- smoke tests,
- timeout tests,
- runtime logs,
- telemetry assertions.

---

## 10. Recommended decision

Adopt Reach experimentally as a **developer analysis tool** for Orchard’s OTP lifecycle modules.

Do **not** start with broad CI enforcement.

Use it first to answer concrete lifecycle questions in this order:

1. `Orchard.Node.ModelManager`
2. `Orchard.Node.ModelManager` + `Orchard.Node.WorkerProcess`
3. `Orchard.Inference.RequestOrchestrator` + `Orchard.Dispatch.RequestDispatcher`
4. `OrchardConsole.ModelHubDownloadCoordinator`
5. scoped dead-code/smell scans after noise is understood

The success criterion should not be “Reach found a bug.” The success criterion should be:

> A reviewer can use Reach output to verify Orchard’s high-risk OTP cleanup, cancellation, terminal-event, and persistence paths faster and with fewer missed edges than manual review alone.