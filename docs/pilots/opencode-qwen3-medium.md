# OpenCode with Qwen3.8 medium in source development

This is an attended, single trusted developer pilot on one Apple Silicon Mac.
PostgreSQL, Controller, NodeAgent, its MLX Worker and OpenCode run on that same
host. The developer reviews the saved changes and test results before accepting
work. The [held qualification record](../model-qualification-records/LMQ-2026-0001.md)
states the observed workflow and its limits. It authorizes no active support claim.

The recipe uses the already registered rendered-input effort contract in
`SPEC.md` §3.4, §3.5 and §7.2.1. It selects medium on the same weights and template;
final-only reasoning output and numeric thinking budgets remain separate.
The source configuration overrides below retain the existing defaults when unset.

## Freeze the source and artifact

Use an isolated checkout of a reviewed Orchard revision and the pinned
[toolchain](../tooling.md). Preserve other checkouts and existing services.
Record full source SHA, tree, dependency locks, host chip/GPU/memory, OS/build,
database version and material settings before the trial. Do not silently label
historical evidence as a run of this recipe's current source.

The artifact is a parser-declared derivative of
`mlx-community/Qwen3.8-27B-8bit@815b83c0df8ffd1d1b5244cf75fd6ef14fca9ef9`:

| Identity | Value |
| --- | --- |
| Local model | `orchard-local/Qwen3.8-27B-8bit-qwen3-coder-tools` |
| Version | `b4e71565ae0f4b842188640b0d479ba0da1635a96297934e8bb6a57a0e1b8573` |
| Catalog Artifact Bundle SHA-256 | `48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9` |
| Template SHA-256 | `c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041` |
| Derived tokenizer-config SHA-256 | `9326181d9b773d6c64a28c5f003ca981f32ecce53e4f558db4c90c4bc8d752f3` |
| Parser | `qwen3_coder` |

The only publisher-file change is the explicit `tool_parser_type: qwen3_coder`
addition in tokenizer_config.json. Weights and template remain byte-identical.
Manifest and static capability sidecar are additional bundle assets, not runtime
qualification. Missing parser declarations are not silently inferred.
Use the offline preparation helper described below, or reuse an existing bundle
whose full ArtifactBundle hash matches. Stop on any identity mismatch. Do not
edit imported Catalog rows, verification receipts or the effort registry to make
a different artifact eligible.

```bash
# Both arguments are absolute operator-selected paths outside this repository.
# SNAPSHOT contains exactly the 19 materialized publisher files; no symlinks.
scripts/prepare-qwen3-medium-bundle.sh "$SNAPSHOT" "$NEW_BUNDLE_DIRECTORY"
```

The destination must not exist and its parent must exist. The helper verifies
the pinned [publisher file inventory](../../scripts/support/qwen3-medium/upstream-files.json),
copies files using ArtifactBundle, adds the one declaration, and calls normal
BundleBuilder with the local revision plus pinned publisher base reference.
It generates the manifest and sidecar from current static preflight rather than
copying historical evidence. The complete 21-file tree must equal the registered
digest before success. A changed serializer, catalog or preflight may cause a
fail-closed mismatch; preserve that destination for inspection and review the
identity change rather than importing it. Any failure after destination creation
can leave a partial copy; preserve it for inspection and do not import it. The
helper will refuse that destination on retry. Allow space for a 29.5 GB copy plus
normal imported/materialized caches. No weights are downloaded by the helper.

## Start one owned stack

Check that the chosen ports and resources are available; preserve unrelated
PostgreSQL, installed Orchard and other services. Use a dedicated local database
and owned data directory. Follow [local development](../local-dev.md) for setup,
trust and migrations. Do not expose this loopback compatibility recipe on a LAN.

```bash
export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
export ORCHARD_WORKER_BACKEND=mlx
export ORCHARD_WORKER_GENERATION_MODE=stream
export ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL=1
export ORCHARD_WORKER_PREFIX_CACHE_MODE=disabled
export ORCHARD_TOKENIZER_SAFE_MODE=off
export ORCHARD_REQUEST_TIMEOUT_MS=1800000
export ORCHARD_MAX_REQUEST_DEADLINE_MS=1800000
export ORCHARD_WORKER_READY_TIMEOUT_MS=30000
export ORCHARD_WORKER_LOAD_TIMEOUT_MS=120000
# Set PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD for the owned local database.
mise exec -- bin/dev
```

This deliberately uses the legacy v2/off tool route tested in the held cell.
Do not disable another source's safe-tokenization policy to copy this pilot.
The default HTTP endpoint is loopback 4000 and the NodeAgent compatibility
endpoint is loopback 50071. `/health/live` must succeed; inspect detailed
readiness rather than interpreting one status alone. Plaintext public API has
HTTPS readiness false and is not globally ready. Missing trust/custody,
unreachable persistence or incomplete migrations block the pilot; disclosure
of a warning does not substitute for those checks.

Import the exact bundle, then create a dedicated tenant, key and routing policy
through normal commands in the running IEx session. Replace placeholders with
the values returned by those commands; do not paste a token into committed config.

```elixir
OrchardCLI.main(["models", "import", "<verified-bundle-directory>", "--activate"])
OrchardCLI.main(["tenants", "create", "--slug", "coding-pilot", "--name", "Coding pilot"])
OrchardCLI.main(["api-keys", "create", "--tenant-id", "<tenant-id>", "--name", "coding-pilot"])
OrchardCLI.main(["models", "routing-policy", "create", "--tenant", "coding-pilot",
  "--name", "preloaded-serial", "--residency-preference", "required_loaded",
  "--max-cold-start-ms", "120000", "--max-queue-wait-ms", "3000"])
OrchardCLI.main(["models", "access", "grant", "<model-id>@<version>",
  "--tenant", "coding-pilot", "--routing-policy-id", "<returned-policy-id>"])
```

Preload through NodeAgent before OpenCode starts. Budgeting acquisition 120000,
Worker readiness 30000 and load 120000 gives an overall 270000 ms envelope; allow
5000 ms RPC headroom. The same planning calculation lives in
`scripts/support/mlx-smoke-budget.sh`. Readiness has its own configured cap;
acquisition and load planning allowances are not independent hard phase caps.
An explicit preload deadline forwards its remaining budget, calculated after
acquisition and before Worker startup, to Worker load. Record the actual load
timeout as well as the overall deadline; readiness time is not deducted from
that forwarded allowance. `ORCHARD_WORKER_LOAD_TIMEOUT_MS` supplies the load
fallback when there is no explicit deadline. In this all-in-one IEx session:

```elixir
model = Orchard.Models.get_model_by_identity("<model-id>", "<version>")
{:ok, channel} = GRPC.Stub.connect("127.0.0.1:50071")
{:ok, status} = Orchard.Cluster.V1.NodeRuntimeService.Stub.get_status(
  channel, %Orchard.Cluster.V1.StatusRequest{})
request = %Orchard.Cluster.V1.EnsureModelLoadedRequest{
  node_id: status.node_metadata.node_id, model_id: model.model_id, version: model.version,
  artifact_sha256: model.artifact_sha256, artifact_source_uri: model.artifact_source_uri,
  preload: true, deadline_unix_ms: System.system_time(:millisecond) + 270_000
}
{:ok, %{placement_state: :PLACEMENT_STATE_LOADED}} =
  Orchard.Cluster.V1.NodeRuntimeService.Stub.ensure_model_loaded(channel, request,
    timeout: 275_000)
```

Confirm the expected model, idle occupancy, one serial slot and Worker provenance.
NodeAgent owns Worker creation, cancellation, unloading and replacement.
First acquisition in a new cache path may do full verification despite matching
artifact bytes; never fabricate a path-bound verification receipt to skip it.

## Configure OpenCode explicitly

The [credential-free example](opencode-qwen3-medium.json) targets OpenCode 1.18.34
and `@ai-sdk/openai-compatible`, using Orchard Chat Completions. Select it in a
fresh work directory with isolated XDG data/cache/state and a protected
`ORCHARD_API_KEY` environment value. It changes no global config and installs
nothing. Inspect `opencode debug config` privately before `opencode run`; avoid
publishing resolved credentials.

Primary, small-model and auxiliary agent routes all select the same admitted
model. `options.reasoningEffort: medium` serializes to Chat `reasoning_effort`;
`reasoning: false` is client output-display metadata, not thinking-off. The
registered omission default is xhigh, so check title requests as well as main
requests for explicit medium. `GET /v1/models`, authenticated as the trial
tenant, must expose the expected `orchard_reasoning_effort` mapping. Unavailable
discovery, unsupported medium or differing identities are stop conditions.

The selected sampling is temperature 1/top_p 0.95. Compaction/pruning are disabled.
Client context 262144 and output 32768 are configured allowances, not tested
maximums. A thirty-minute per-request stream/header watchdog covers buffered
tool arguments that produce no visible chunks for minutes. `timeout: false`
does not disable those watchdogs or Orchard's request deadline. It does not set
a whole coding-session duration. Keep an explicit task/request-count guard and
human supervision; the held case declared a guard of 24 forwarded requests,
including auxiliary calls and retries, and actually forwarded 16.

Use only a bounded repository whose tool permissions and original acceptance
tests are approved. The example allows local coding tools and denies web and
external-directory access; that configuration is not an OS sandbox. Capture
request IDs, terminal state, actual effort and usage without logging tokens.
The prior evidence used a pass-through capture proxy on 4100; this direct 4000
example is a changed client path and has only configuration validation until
separately exercised. No field injection is required for medium.

Title generation can occupy the single slot while the main request arrives.
Retryable `cluster_busy` remains a real rejection, including when carried as an
error inside HTTP 200 SSE. Record it; never count HTTP 200 alone as success.

## Review and stop

Success requires natural agent completion, substantive saved changes, unchanged
original tests, meaningful added regressions and a truthful final summary.
Seal the workspace and receipts before independent tests/review; do not feed
private acceptance checks back to the model. Passing tests do not make generated
code automatically acceptable. Record failures and human findings separately
from Orchard transport/lifecycle defects and descriptive elapsed time.

Stop admission for artifact/proof mismatch, auth/tool-scope breach, unsafe
pressure, altered acceptance tests or unknown execution custody. Use NodeAgent
cancellation/unload, verify terminal requests and safe reuse, then revoke only
owned access and stop only owned services. Preserve data and seals. A cancel
ACK or logical counter reaching zero is insufficient proof of native drain;
unknown custody requires capacity to remain unavailable. No direct Worker kill,
manual row terminalization, global-default change or distribution activation is
part of this recipe.

The held cell covers one warm Chat-streaming workflow. Responses, safe-v3,
maximum context/output, paired post-cancel follow-up, fault recovery and shared
multi-user/multi-node operation need separate evidence. The served-code result
does not imply any of those cells passed.
