# Source-dev Two-Mac Smoke - 2026-07-06

## Summary

Result: completed with one surface gap.

This smoke validated source-dev BEAM Runtime Endpoint mode across two Macs on Orchard `main` after merge commit `e60cc598a45245951dd337659c0695c64d2aa8c6`.
The run exercised bring-up, cluster status, admission, a real MLX chat completion, persisted single-target scheduler explanations, lifecycle cancel-drain, write-gate sanity, decommissioning, and teardown.
No product code was changed.
The only committed artifact from this run is this evidence note.

The PR #67 memory-budget status-surface check did not fully pass through the requested CLI surface.
`orchardctl nodes inspect --json` did not render a memory-budget block in this run.
A Runtime Endpoint snapshot did expose `recommended_context_tokens`, and the catalog row exposed `max_context_tokens`, so the underlying data was present.
This remains a surface-evidence gap for follow-up.

Smoke date: 2026-07-06.
Smoke completion time: 2026-07-06T06:09:56Z.
Tested code state: `e60cc598a45245951dd337659c0695c64d2aa8c6`.
Test branch for evidence commit: `najibninaba/smoke-main-e60cc59`.

## Hosts

Controller host: `tamingsari`.
Controller Tailscale IP: `100.90.207.78`.
Controller checkout: `/Users/najib/Hacks/orchard`.

Remote node-agent host: `mawarduri`.
Remote node-agent Tailscale IP: `100.70.81.109`.
Remote checkout: `~/Hacks/orchard`.
Remote checkout was fast-forwarded to `e60cc598a452` before the smoke.
Remote dependencies were refreshed with `mise exec -- mix deps.get`, `mise exec -- uv sync --directory native/orchard_tokenizer`, and `mise exec -- uv sync --directory native/orchard_worker_mlx --extra mlx`.

Controller BEAM node name: `orchard_controller@100.90.207.78`.
Remote node-agent BEAM node name: `orchard_node_agent@100.70.81.109`.
The run used EPMD port `43690` on both Macs because packaged Orchard and local EPMD state may occupy the default port.
The shared BEAM cookie was stored in owner-only transient files and was removed during teardown.
Cookie SHA-256 digest: `68d8cc1aabc0ed0aed8698798bc2642bb698318ec1cd4d7683acf1a73333e09a`.
Cookie contents and API token material are intentionally omitted.

Packaged Orchard BEAM processes under `/Library/Application Support/Orchard` were present on the controller host and were ignored.
The source-dev smoke used HTTP `127.0.0.1:4000` and the source checkout.

## Launch Commands

The remote node-agent was started on `mawarduri` with this sanitized command shape:

```bash
ssh najib@100.70.81.109 "zsh -lc '<remote setup>'"
screen -L -dmS orchard-smoke-node-e60cc59 zsh -lc '
  cd ~/Hacks/orchard &&
  env \
    ORCHARD_BEAM_NODE_NAME=orchard_node_agent@100.70.81.109 \
    ORCHARD_BEAM_COOKIE_FILE=<shared-cookie-file> \
    ORCHARD_BEAM_EPMD_PORT=43690 \
    ORCHARD_NODE_DISPLAY_NAME=mawarduri-smoke-e60cc59 \
    mise exec -- bin/dev-node-agent
'
```

The controller was started on `tamingsari` with this sanitized command shape:

```bash
screen -L -dmS orchard-smoke-controller-e60cc59 zsh -lc '
  cd /Users/najib/Hacks/orchard &&
  env \
    ORCHARD_BEAM_NODE_NAME=orchard_controller@100.90.207.78 \
    ORCHARD_BEAM_COOKIE_FILE=<shared-cookie-file> \
    ORCHARD_BEAM_EPMD_PORT=43690 \
    ORCHARD_RUNTIME_ENDPOINT_TARGETS=orchard_node_agent@100.70.81.109 \
    ORCHARD_NODE_DISPLAY_NAME=tamingsari-controller-smoke-e60cc59 \
    mise exec -- bin/dev-controller
'
```

`screen -L -dmS` was used as a persistent TTY wrapper because direct `nohup` source-dev IEx starts exited on EOF during remote SSH attempts.
This was an operator wrapper only and did not change product code.

## Model And API Evidence

The smoke used the same small MLX model as the prior accepted note:

```text
mlx-community/Llama-3.2-1B-Instruct-4bit@08231374eeacb049a0eade7922910865b8fce912
```

The remote worker loaded the model from the source-dev cache.
The node-agent log reported `load_model ok` and `generate done` for request `chatcmpl-a5ba2ade-97a7-42b4-948a-7e1effbde2c6`.

`POST /v1/chat/completions` returned HTTP `200` through the authenticated public API.
The response id was `chatcmpl-a5ba2ade-97a7-42b4-948a-7e1effbde2c6`.
The response content was `mlx ready`.
The finish reason was `stop`.
Usage was `45` total tokens, `42` prompt tokens, and `3` completion tokens.

`orchardctl requests inspect chatcmpl-a5ba2ade-97a7-42b4-948a-7e1effbde2c6 --json` returned a persisted scheduler explanation.
It selected node `6ec44363-70d4-456a-835c-73112994bc5c`.
It included one scored candidate for the same node.
The candidate was eligible, used tier `cold`, and scored `141` with components `health_bonus: 30`, `load_bonus: 40`, `rank_base: 71`, and `residency_bonus: 0`.
`rejected_candidates` and `skipped_candidates` were empty.

## Checklist Evidence

| Item | Command or probe | Expected | Observed | Result |
| --- | --- | --- | --- | --- |
| 1. Bring-up | `curl http://127.0.0.1:4000/console/nodes`, `screen -ls`, remote `screen -ls`, source logs, and BEAM Runtime Endpoint probes. | Controller HTTP is up, both source-dev processes are running, and the controller can reach the node-agent target. | Controller HTTP returned `200`, local screen `orchard-smoke-controller-e60cc59` was detached, remote screen `orchard-smoke-node-e60cc59` was detached, remote EPMD listened on `100.70.81.109:43690`, and the real chat completion later proved BEAM dispatch to mawarduri. | PASS |
| 1. Cluster status | `mise exec -- mix run -e 'OrchardCLI.main(["cluster","status","--json"])'`. | `orchardctl cluster status --json` works and shows single-controller mode plus advisory-lock status. | `deployment_mode` was `single_controller`, `controller_role` was `single_controller`, `advisory_lock_status` was `unknown`, and `standby_write_path_behavior` was `writes_allowed_when_authorized`. | PASS |
| 2. Node admission candidate | Runtime Endpoint observation and admission DB evidence. | mawarduri appears as an observed admission candidate. | The observed mawarduri identity used node id `6ec44363-70d4-456a-835c-73112994bc5c`, agent version `0.5.0-dev`, hostname `mawarduri`, and display name `mawarduri`. | PASS |
| 2. Node admission preview and execute | `orchardctl nodes admit 6ec44363-70d4-456a-835c-73112994bc5c --dry-run --json ...` and `orchardctl nodes admit 6ec44363-70d4-456a-835c-73112994bc5c --yes --json ...`. | Preview has no blockers and execute admits the node. | Preview had no blockers, execute produced decision `admitted`, audit log id `53`, decision id `3cf4c579-be3c-4588-b349-3ae4afbc8689`, pool id `0eacb8c5-1cb9-484c-9b1b-a79524c4d8ea`, and routing id `072ec64b-8941-4e77-9873-9d364fd96d44`. | PASS with caveat |
| 2. Admission caveat | `orchardctl nodes admit <observed-candidate-id> --dry-run --json`. | The operator can admit the intended mawarduri target. | Direct admission by raw observed candidate id returned `node_not_found`, so a registered node row was created from the observed mawarduri candidate before running the CLI admission path. | CAVEAT |
| 3. Single-target scheduler explanation | `POST /v1/chat/completions` followed by `orchardctl requests inspect chatcmpl-a5ba2ade-97a7-42b4-948a-7e1effbde2c6 --json`. | A real chat completion succeeds and the persisted request inspect output includes a scheduler explanation for the single mawarduri target. | The chat returned HTTP `200` with content `mlx ready`, and request inspect showed one eligible scored candidate for node `6ec44363-70d4-456a-835c-73112994bc5c`. | PASS |
| 4. Memory-budget status surface | `orchardctl nodes inspect 6ec44363-70d4-456a-835c-73112994bc5c --json`, Runtime Endpoint memory-budget snapshot, and catalog query. | The node status surface shows the memory-budget block including `recommended_context_tokens` alongside catalog `max_context_tokens`. | Runtime Endpoint data showed `recommended_context_tokens: 131072`, `status_code: ok`, `budget_available: true`, `headroom_available: true`, `target_working_set_bytes: 50096509747`, and `resident_memory_bytes: 695242752`. The catalog row showed `max_context_tokens: 131072`. `orchardctl nodes inspect --json` did not render the memory-budget block. | FAIL for requested CLI surface |
| 5. Cordon | `orchardctl nodes cordon <node-id> --dry-run --json` then `orchardctl nodes cordon <node-id> --yes --json`. | Preview has no blockers and execute moves active to cordoned. | Preview had no blockers and expected `active` to `cordoned`. Execute returned action `node_lifecycle.cordoned`, audit log id `56`, and node state `cordoned`. | PASS |
| 5. Drain | `orchardctl nodes drain <node-id> --dry-run --json` then `orchardctl nodes drain <node-id> --yes --json --acknowledge`. | Preview has no blockers and execute moves cordoned to draining. | Preview had no blockers, required `--yes` plus acknowledgement, and listed `existing_requests_continue_until_deadline`. Execute returned action `node_lifecycle.drain_started`, audit log id `57`, and node state `draining`. | PASS |
| 5. Cancel drain | `orchardctl nodes cancel-drain <node-id> --dry-run --json` then `orchardctl nodes cancel-drain <node-id> --yes --json`. | Preview has no blockers while draining and execute moves the node to cordoned. | Preview had no blockers and expected `draining` to `cordoned`. Execute returned action `node_lifecycle.drain_cancelled`, audit log id `58`, and node state `cordoned`. | PASS |
| 5. Cancel-drain blocker | `orchardctl nodes cancel-drain <node-id> --dry-run --json` after the node was cordoned. | Preview on a non-draining node shows `drain_not_running`. | Preview returned blocker code `drain_not_running` and left the expected transition as `cordoned` to `cordoned`. | PASS |
| 5. Uncordon | `orchardctl nodes uncordon <node-id> --dry-run --json` then `orchardctl nodes uncordon <node-id> --yes --json`. | Preview has no blockers and execute returns the node to active. | Preview had no blockers and expected `cordoned` to `active`. Execute returned action `node_lifecycle.uncordoned`, audit log id `59`, and node state `active`. | PASS |
| 6. Write gate sanity | `orchardctl cluster status --json` plus the successful admission and lifecycle writes. | Single-controller mode writes are allowed. | Cluster status reported `writes_allowed_when_authorized`, and admission plus lifecycle write actions succeeded. | PASS |
| 6. Active/Standby denial | Not run. | The `controller_leadership_unproven` denial requires an Active/Standby two-controller topology. | This smoke used single-controller mode only. | NOT EXERCISED |
| 7. Node removal | `orchardctl nodes decommission <node-id> --dry-run --json` then `orchardctl nodes decommission <node-id> --yes --acknowledge --typed-node-id <node-id> --json`. | Preview has no blockers and execute moves the node to `decommissioning` or `removed`. | Preview had no blockers and consequence codes `future_scheduling_revoked` and `no_rejoin_with_same_node_id`. Execute returned action `node_lifecycle.decommission_started`, audit log id `60`, and node state `decommissioning`. | PASS |
| 7. Drop from scheduling | `Orchard.Nodes.schedulable_nodes()` after decommission. | The removed or decommissioning node is not schedulable. | The query returned `[]`. | PASS |
| 8. Teardown | Stop both screens, kill leftover source-dev smoke PIDs, kill EPMD `43690`, remove cookie files, and re-check processes. | Both dev servers stop, cookie files are removed, and no smoke BEAM processes remain on either host. | After a targeted correction pass, no smoke BEAM processes remained, port `43690` was clear on both hosts, local HTTP `4000` returned `000`, and both transient cookie files were absent. | PASS |

## Lifecycle Audit Trail

The node lifecycle audit trail contained these records for node `6ec44363-70d4-456a-835c-73112994bc5c`:

| Audit id | Action | Transition |
| --- | --- | --- |
| 56 | `node_lifecycle.cordoned` | `active` to `cordoned` |
| 57 | `node_lifecycle.drain_started` | `cordoned` to `draining` |
| 58 | `node_lifecycle.drain_cancelled` | `draining` to `cordoned` |
| 59 | `node_lifecycle.uncordoned` | `cordoned` to `active` |
| 60 | `node_lifecycle.decommission_started` | `active` to `decommissioning` |

## Not Exercised

`cluster_busy` saturation shift was not exercised because the smoke did not create saturation.
Memory-budget enforce abort was not exercised because the smoke did not create real memory pressure.
TokenDelta opt-in was not exercised because it is an internal wire surface.
Active/Standby leadership denial was not exercised because the smoke did not start a second controller.
MLX bump items from issue `#65` were not exercised.

## Residual Risks And Notes

The memory-budget data path was present in Runtime Endpoint evidence, but the requested `orchardctl nodes inspect` status surface did not render the memory-budget block.
That is the only failed checklist surface in this run.

The admission flow required creating a registered node row from the observed mawarduri candidate before using `orchardctl nodes admit`.
Direct CLI admission by raw observed candidate id returned `node_not_found`.
This may be expected for the current CLI contract, but it is a smoke caveat because the checklist phrased mawarduri as an observed candidate target.

After the successful chat completion, later CLI lifecycle snapshots showed `node_observation_stale` in scheduler eligibility.
The node remained lifecycle-active before decommission, and the request-inspect scheduler explanation from the real completion captured the node as eligible at scheduling time.

The source CLI command form used during the smoke was `mise exec -- mix run -e 'OrchardCLI.main([...])'`.
It starts enough application context to emit debug logs, so the raw local evidence logs are noisy.
Those transient logs were kept under `tmp/dev/smoke-e60cc59-evidence/` and are intentionally not committed.

The first teardown pass stopped the screen sessions but left child BEAM processes running.
A targeted correction pass killed only the source-dev smoke PIDs and the nonstandard EPMD listeners on port `43690`.
The final teardown check showed no smoke BEAM processes and no `43690` listeners on either Mac.
