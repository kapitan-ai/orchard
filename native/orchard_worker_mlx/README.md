# orchard_worker_mlx

Orchard's MLX worker runtime package — a gRPC service that owns model loading,
inference generation, and health probing for Apple Silicon (MLX) backends.

## Entrypoints

- project script (run from `native/orchard_worker_mlx/`): `mise exec -- uv run orchard-worker-mlx`
- dev-only repo wrapper from the repo root: `mise exec -- native/orchard_worker_mlx/bin/orchard-worker-mlx`

See `../../docs/tooling.md` for the required mise and uv workflow.

## Responsibility boundary

The worker owns local model loading, generation, prefix-cache/runtime telemetry,
and MLX backend integration. The node agent supervises the worker process and is
the network-reachable boundary for controller dispatch. Public clients never call
this service directly.

See `../../docs/architecture.md` for the broader runtime map.

## Backend modes

The standalone CLI supports `--backend stub` and `--backend mlx`. The CLI
defaults to `stub` for hermetic local checks; the node-agent source and packaged
runtime defaults `ORCHARD_WORKER_BACKEND` to `mlx`. Install MLX extras before
using the real backend:

```bash
mise exec -- uv sync --locked --directory native/orchard_worker_mlx --extra mlx
```

The CLI also supports `--generation-mode stream|batch`. The stub backend uses
`stream` when no generation mode is provided and rejects `batch`; the node-agent
source and packaged runtime configs mirror that by resolving
`ORCHARD_WORKER_BACKEND=stub` to stream mode when
`ORCHARD_WORKER_GENERATION_MODE` is unset.
In node-agent runtime, batch mode can admit concurrent same-model requests up to the worker-reported effective request limit.
That limit is configured with `ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL` or, when set to `auto`, `ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL`.
The worker `GetStatus` path reports overlapping `Generate` calls and effective worker capacity through `WorkerStatusResponse.active_request_count` and `WorkerStatusResponse.max_concurrency`.
The node-agent publishes aggregate capacity through cluster `StatusResponse.active_request_count` and `StatusResponse.max_concurrency`, plus loaded-placement capacity through `StatusResponse.runtime_model_placements`.
Aggregate capacity is the conservative limit the node agent enforces across loaded workers, while each loaded placement keeps its own reported capacity.

## MLX-LM security baseline

The `mlx` extra pins MLX-LM commit `ab1806e8f5d6aa035973af194a1b9198ab4754dc`.
The reviewed source range contains 15 commits and 35 changed files after the `v0.31.3` tag.
The dependency still reports version `0.31.3`, so the full Git revision and committed uv lock are the runtime provenance authority.
Transformers remains constrained to `>=5.7,<5.13` until its broader compatibility matrix is accepted separately.

Orchard rejects model configurations containing `model_file` before upstream loading.
The production loader also passes `trust_remote_code=False` for model loading and `tokenizer_config_extra={"trust_remote_code": False}` for tokenizer loading.
Resolved-environment tests verify the same explicit settings on MLX-LM's sharded loading surface.
These controls reduce dynamic-code exposure but do not make model execution a security sandbox.

Residual: MLX-LM's `sharded_load` falls back to `{"trust_remote_code": True}` for the tokenizer whenever `tokenizer_config` is omitted or empty, so its model-side `trust_remote_code=False` does not cover the tokenizer by itself.
Orchard does not reach that path today; issue #116 sharded loading must pass an explicit `{"trust_remote_code": False}` tokenizer config rather than relying on the upstream default.

## Tool calling qualification

The worker buffers each complete model-native tool block, delegates interpretation to the pinned MLX-LM parser, and emits only validated function names and JSON argument objects.
Raw model wrappers never become public arguments.
Cancellation, incomplete framing, invalid parser results, and unrequested names cannot publish the affected block.

Qualify each exact model/runtime/client combination before declaring tool support:

1. Record the immutable model revision, manifest identity, effective context and concurrency, MLX-LM Git revision, parser identity, client version, and API path.
2. Verify the bundle declares tool capability and the loaded tokenizer exposes a supported parser.
3. Run the pinned-parser regression tests and the real-template continuation test documented in `../orchard_tokenizer/README.md`.
4. Through Chat Completions, require the client to call a local tool against a synthetic fixture, validate its arguments, return the result with the matching call ID, and reproduce an unpredictable fixture value in the final answer.
5. Exercise cancellation and recovery, malformed/truncated calls, and sequential tool turns; distinguish protocol failures from model choices.

The qualification harness must fail on a nonzero client exit, missing output, error events, incomplete tool execution, or an incorrect final fixture value.
Record the fixture before each run and verify the completed tool's arguments and returned contents against that snapshot.
An empty client transcript is a blocked run, never a pass.
Use a portable bounded watchdog on macOS rather than assuming GNU `timeout` is installed.

For source-development runs, verify that PostgreSQL sessions use UTC before evaluating heartbeat freshness.
Record cold-load and preloaded results separately.
Between independent direct-API cases at concurrency one, wait for an idle heartbeat observed after the preceding request's terminal boundary; an older idle snapshot cannot establish recovery.
Do not insert this pacing inside the client under qualification, because normal client sequencing is part of the assertion.
See [model qualification policy](../../docs/model-qualification.md) for the required evidence and support-claim boundaries.

`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` at revision `6e302ea604ad9ab206367e2c501d1571023e7b6d` uses the `qwen3_coder` parser.
OpenCode 1.18.25 exercised the preloaded source-development profile at a 16,384-token context, 1,024 output tokens, and one concurrent request.
Completed read-tool round trips reproduced exact synthetic file values, including three fresh-nonce runs and two-file and three-file sequences.
These results establish bounded client round-trip evidence, not an approved model support claim.
OpenCode cancellation remains unverified because the client-cancellation harness did not deliver its signal correctly.
Some tool-history continuations emitted an incomplete trailing tool marker after useful text; the worker rejected that malformed output instead of publishing an unvalidated call.
Cold-load reliability, broader model behavior, and unrestricted coding-agent operation require separate qualification.
OpenCode also sends parallel title/summary requests; at concurrency one, the capture included transient `cluster_busy` responses and client retries.
Successful primary read turns do not establish contention-free operation.
Chat Completions qualification does not establish Responses API compatibility.

### Repeat an OpenCode read-tool smoke

Use an isolated synthetic workspace with OpenCode 1.18.25 and provide the tenant API key through `ORCHARD_API_KEY`.
Replace `<model-alias>` with the complete `<model_id>@<version>` returned by `GET /v1/models`, `<host>` with the Orchard endpoint, and `<workspace>` with the synthetic workspace's absolute path.
Save this configuration as `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "share": "disabled",
  "autoupdate": false,
  "enabled_providers": ["orchard"],
  "model": "orchard/<model-alias>",
  "permission": {"*": "deny", "read": "allow", "external_directory": "allow"},
  "provider": {
    "orchard": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Orchard",
      "options": {
        "baseURL": "https://<host>/v1",
        "apiKey": "{env:ORCHARD_API_KEY}",
        "timeout": 300000
      },
      "models": {
        "<model-alias>": {
          "name": "<model-alias>",
          "tool_call": true,
          "reasoning": false,
          "attachment": false,
          "limit": {"context": 16384, "output": 1024}
        }
      }
    }
  },
  "agent": {
    "readonly": {
      "mode": "primary",
      "tools": {"*": false, "read": true},
      "permission": {"*": "deny", "read": "allow", "external_directory": "allow"},
      "prompt": "Use the read tool for requested files. The synthetic workspace is <workspace>; use absolute paths when needed and answer with exact file contents."
    }
  }
}
```

This template restricts the global permission map to the read-only agent's effective permissions.
The measured run additionally used isolated user/config directories and a local capture proxy; equivalent isolation and redacted request capture are required when reproducing its evidence.
Create `notes/token.txt` with a fresh unpredictable value, retain that value outside the prompt, then run from the synthetic workspace under a 600-second process watchdog:

```bash
OPENCODE_CONFIG="$PWD/opencode.json" opencode run --pure --format json --agent readonly \
  "Read notes/token.txt and tell me the exact token it contains." > out.jsonl
```

Require a zero exit status, a completed `read` tool event for the expected file, the exact fixture value in the final text, and no client error events.
Inspect the captured continuation to verify that the assistant call and tool result retain the same call ID and that the public request uses `max_tokens: 1024`.
Repeat with three fresh values, then two and three separate files, without resetting caches or restarting Orchard.
Record background-request admission failures and retries even when the primary answer succeeds.

## Proto contract

The provider-neutral Worker Runtime proto lives at:

```
proto/orchard/worker/v1/worker_runtime.proto
```

This defines the internal node-agent ↔ worker gRPC contract (`WorkerRuntimeService`).
It is owned outside this provider implementation and imports shared cluster types from `proto/cluster/v1/`.

### Generated bindings

| Surface | Location | Generation |
|---------|----------|------------|
| Python messages | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2.py` | `mise exec -- mix proto.gen.worker` |
| Python gRPC stubs | `src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2_grpc.py` | `mise exec -- mix proto.gen.worker` |
| Elixir modules | `apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex` | `mise exec -- mix proto.gen.worker` |
| Descriptor golden | `proto/orchard/worker/v1/worker_runtime.descriptor.pb` | `mise exec -- mix proto.gen.worker` |

### Regenerate bindings

From the repo root:

```bash
mise exec -- mix proto.gen.worker
```

This runs the `grpcio-tools` version pinned by `proto/orchard/worker/tooling/uv.lock` and `protoc-gen-elixir` 0.16.0 with the correct include paths.
It generates both language surfaces from the one neutral schema.
The provider package carries only the protobuf and gRPC runtime dependencies needed to consume its generated bindings.

The Elixir generator output is mechanically mapped to the existing `Orchard.Node.Worker.V1.*` namespace and existing `Orchard.Cluster.V1.*` imported types.
No message, field, RPC, package, or service definition is maintained by that mapping.

### Drift validation

From the repo root:

```bash
mise exec -- mix proto.check.worker
scripts/test-worker-runtime-binding-drift.sh
```

The first command regenerates every committed Python and Elixir binding plus the descriptor golden into a temporary root and byte-compares the results.
The second command introduces drift only in a temporary fixture and proves the checker rejects it.

### Workflow rules

1. Edit the `.proto` source first.
2. Run `mise exec -- mix proto.gen.worker` to regenerate every binding and the descriptor golden.
3. Run `mise exec -- mix proto.check.worker` and the reciprocal compatibility tests.
4. Commit the canonical schema and every generated output together.
