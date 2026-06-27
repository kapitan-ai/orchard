# Source-dev BEAM Two-Mac Smoke - 2026-06-27

## Summary

Result: passed.

This smoke validated explicit Source-dev BEAM Runtime Endpoint mode across two Macs before considering a later change that promotes BEAM as the source-dev default.
It did not change the default source-dev transport.
It did not rely on automatic gRPC fallback.

Smoke date: 2026-06-27.
Smoke time: 2026-06-27T02:42:21Z.
Tested code state: base commit `995879a13710ba39ec22c316d91ca5b3f356c2ec` plus the local branch patch that keeps source-dev worker Unix sockets under a short `/tmp/od-<hash>/ws` root.
No Runtime Endpoint transport implementation files differed from the base commit during the smoke.

## Hosts

Controller host: `controller-mac`.
Local node-agent host: `controller-mac`.
Remote node-agent host: `remote-worker-mac`.

Controller BEAM node name: `orchard_controller@192.0.2.10`.
Local node-agent BEAM node name: `orchard_node_agent@192.0.2.10`.
Remote node-agent BEAM node name: `orchard_node_agent@192.0.2.20`.

The run used an alternate EPMD port, `43690`, because the remote Mac already had default EPMD and packaged Orchard state on the standard port.
The shared BEAM cookie was provisioned from a local transient file to the remote worktree and verified by digest comparison.
Cookie contents and API token material are intentionally omitted.

## Launch Commands

The remote node agent was started on `remote-worker-mac` with this sanitized command shape:

```bash
ssh -tt remote-worker-mac env \
  ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam \
  ORCHARD_BEAM_EPMD_PORT=43690 \
  ORCHARD_BEAM_NODE_NAME=orchard_node_agent@192.0.2.20 \
  ORCHARD_BEAM_COOKIE_FILE=<shared-cookie-file> \
  ORCHARD_WORKER_BACKEND=stub \
  ORCHARD_NODE_DISPLAY_NAME=remote-worker-mac-smoke \
  mise exec -C <remote-worktree> -- bin/dev-node-agent
```

The local node agent was started on `controller-mac` with this sanitized command shape:

```bash
env \
  ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam \
  ORCHARD_BEAM_EPMD_PORT=43690 \
  ORCHARD_BEAM_NODE_NAME=orchard_node_agent@192.0.2.10 \
  ORCHARD_BEAM_COOKIE_FILE=<shared-cookie-file> \
  ORCHARD_WORKER_BACKEND=stub \
  ORCHARD_NODE_DISPLAY_NAME=controller-mac-node-smoke \
  mise exec -- bin/dev-node-agent
```

The controller was started on `controller-mac` with this sanitized command shape:

```bash
env \
  ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam \
  ORCHARD_BEAM_EPMD_PORT=43690 \
  ORCHARD_RUNTIME_ENDPOINT_TARGETS=orchard_node_agent@192.0.2.10,orchard_node_agent@192.0.2.20 \
  ORCHARD_BEAM_NODE_NAME=orchard_controller@192.0.2.10 \
  ORCHARD_BEAM_COOKIE_FILE=<shared-cookie-file> \
  ORCHARD_NODE_DISPLAY_NAME=controller-mac-controller-smoke \
  mise exec -- bin/dev-controller
```

## Runtime Endpoint RPC Evidence

The controller called the BEAM Runtime Endpoint client against both configured node-agent targets.

```elixir
alias Orchard.RuntimeEndpoint.{BeamClient, Observation, Target}

[
  {"controller-mac", "orchard_node_agent@192.0.2.10"},
  {"remote-worker-mac", "orchard_node_agent@192.0.2.20"}
]
|> Enum.map(fn {label, address} ->
  target = Target.normalize(%{transport: :beam, address: address, id: "beam:" <> address})
  {:ok, connection} = BeamClient.connect(target)
  {:ok, observation} = BeamClient.status(connection, timeout: 10_000)

  {
    label,
    Atom.to_string(target.address),
    observation.availability,
    observation.worker_state,
    Observation.node_id(observation),
    length(observation.placements),
    observation.supports_prompt_token_ids
  }
end)
```

The result was:

```elixir
[
  {"controller-mac", "orchard_node_agent@192.0.2.10", :available, :idle,
   "e640079f-6786-482e-9b1a-5cc0b361872c", 1, true},
  {"remote-worker-mac", "orchard_node_agent@192.0.2.20", :available, :idle,
   "9ec667b3-14bc-437d-80bc-f0d0bc210acb", 0, false}
]
```

Both Runtime Endpoint targets were reachable over BEAM Distribution.
The local target reported one loaded placement after the chat completion run.
The remote target reported no loaded models, which matched the scheduler choosing the local placement for the request.

## Model And API Evidence

The model probe used `mlx-community/Llama-3.2-1B-Instruct-4bit@08231374eeacb049a0eade7922910865b8fce912`.
The same model bundle was available on both Macs before the smoke.

`GET /v1/models` returned `200` through the authenticated API.

```json
{"object":"list","count":4,"llama":"mlx-community/Llama-3.2-1B-Instruct-4bit@08231374eeacb049a0eade7922910865b8fce912"}
```

`POST /v1/chat/completions` returned `200` through the authenticated API using the same model.

```json
{"id":"chatcmpl-661f4591-5160-41ab-a911-8a188af174d6","model":"mlx-community/Llama-3.2-1B-Instruct-4bit@08231374eeacb049a0eade7922910865b8fce912","content":"mlx ready","finish_reason":"stop"}
```

The controller dispatch timing log reported outcome `ok` for that request.
The local node-agent worker logs showed the source-dev worker socket path under `/tmp/od-<hash>/ws` and completed stub worker generation.

## Console Evidence

The Console Nodes page was verified in a connected browser session against `http://127.0.0.1:4000/console/nodes`.
The page title was `Nodes`.
The connected LiveView reported `2 target(s) configured, 2 reachable`.

The `controller-mac` BEAM runtime card used `orchard_node_agent@192.0.2.10`.
It reported `Idle`, `Healthy`, `Prompt IDs: capable`, backend `stub`, and the Llama model placement.

The `remote-worker-mac` BEAM runtime card used `orchard_node_agent@192.0.2.20`.
It reported `Idle`, `Healthy`, `Prompt IDs: legacy`, backend `stub`, and no loaded models.

The transient screenshot was saved under `tmp/dev/console-nodes.png` during the run and is intentionally not committed.

## Residual Notes

The run logged stale node identity conflict warnings for the legacy `127.0.0.1:50071` advertised target in the local development database.
Those warnings did not prevent BEAM Runtime Endpoint RPC, Console reachability, model listing, or chat completion.
They should be cleaned up or suppressed separately if they keep confusing Console smoke output.

The accepted gate now has two-Mac BEAM smoke evidence, but default promotion still belongs in a separate OpenSpec change.
gRPC compatibility remains explicitly selectable and remains the current source-dev default until that later promotion is approved.
