# Agentic Execution corpus, version 1

This model-free fixture exercises SPEC §7.2.9 through Phoenix's public Endpoint,
request normalization and governance, the real tokenizer helper in segmented
`reject` mode, Controller dispatch, the gRPC Runtime Endpoint, Node WorkerProcess,
durable Request evidence, and public serializers. The production Worker Runtime
adapter crosses its Unix-socket gRPC transport into the production native
`WorkerRuntimeServicer`; only generation is scripted by `tests/agentic_worker.py`.
The bundle uses test-only sentinel weights and the existing
byte-level tokenizer fixture; no model download or accelerator is involved.

Run from the umbrella root with the prepared disposable test database:

```sh
mise exec -- uv sync --locked --directory native/orchard_worker_mlx
mise exec -- mix test apps/orchard_controller/test/orchard/inference/agentic_execution_corpus_test.exs --seed 0
```

Set `ORCHARD_AGENTIC_RESULTS` to a new output file to append sanitized JSONL
results. Results identify corpus version, Orchard revision, dirty-worktree
state and SHA-256 of the HEAD diff, untracked file names/bytes, and corpus,
synthetic client, runtime fixture,
endpoint/mode, output contract, and
assertion statuses. They deliberately omit observed content and identifiers.
The results file itself is excluded from the dirty-worktree state and input
hash, so appending records does not change later records. The runtime fixture
is `native-worker-runtime/scripted-backend/v1` for cases that run the native
Worker, `controller-managed-runtime-script/v1` for the managed-retry lane, and
`controller-policy-only/v1` for `controller-policy` cases, which call ranking,
allocation or retry code directly and run no Worker.
Use a fresh file for each invocation: the runner does not truncate existing
evidence. JSONL records are ordered by test execution, so compare sorted records
when changing the ExUnit seed. A failed invocation is not conformance evidence
even when some records pass; absent records are not passes.

## Fixture fields

- `version` and `client_adapter` identify the fixture and the synthetic client.
- `modes` names the four public API modes. A case may narrow that list.
- `request` supplies public fields, merged with a synthetic model, user input,
  and the declared stream mode. Chat streaming requests include usage.
- `events` is an ordered provider-neutral script: text deltas, indexed tool-call
  deltas, cumulative usage, completion, or failure. No event executes a tool.
- `expected` independently declares output bytes, call identities/arguments,
  usage totals, terminal counts, client decisions, and synthetic effects.
- `continuation` is a second public request. Its history comes from the public
  response and client results, never directly from expected call fixtures.
  Independent `expected_history` checks dispatched call/result correlation,
  order and values, including SPEC §3.5 contract-v3 argument-object rendering.
  Each assistant call is projected separately to compare Chat's grouped calls
  with Responses' individual call items without erasing call/result order.
- `fault` corrupts the observed Runtime Endpoint stream after the real gRPC
  transport, allowing missing/duplicate/post-terminal evidence to be tested
  independently of WorkerProcess's own terminal guard.
- `dependency_blocked` is reserved for positive public inputs that do not exist,
  currently explicit `final_only`. It is not a passing assertion.

Every executable fixture is replayed twice and compares normalized observations,
not just pass/fail totals. Dynamic public request IDs and timestamps are not
compared. The structured-output negative control replays malformed JSON through
the public path, requires the independent oracle to fail, then replays the
uncorrupted fixture. Other oracle controls change JSON values, usage direction,
terminal count, terminal kind/status, content-part types, finish reason, and
terminal ordering without altering production code. Continuation controls drop
or change a client result through the public path, then restore the good input.

The synthetic client supports only the corpus's `scale` schema and multiplies
its integer argument by five. It checks that effective caller schema before
recording effects. It is not a general JSON Schema implementation or a claim of
support for an external client. Its effects are evidence only of this synthetic
client's decisions, not an independent audit proving zero Orchard tool execution.

## Incomplete profile boundaries

The corpus is intentionally not a qualification or activation record.
Success streams check independent fragment expectations, Chat call indices and
IDs, and Responses lifecycle order, sequence, full item contents, identity and
argument correlation. Sequence, correlation, terminal-identity, item-content
and premature-terminal mutations must fail. Failure streams check declared
fragment contents, response/text identity, sequence and terminal ordering.
Exhaustive failure-trace mutations remain incomplete.

The public disconnect case injects a closed Plug write, observes cancellation
inside the scripted native backend, and holds that backend behind a drain gate.
Node occupancy remains held until the gate opens; the logical Request cancels
once without retry. A scripted capacity-policy scheduler connects the production
allocation authority to this route. Cooperative drain retains Controller
allocation; timeout checks require quarantine and reject allocation reuse while
native generation is still held, and that quarantine persists after the drain
gate opens. Current source fails those three timeout assertions even though Node
occupancy remains held. They are SPEC §7.2.9 profile gates, stricter than the
§4.6.2 base contract, which lets affirmative stream closure resolve execution
and quarantines only admitted Nodes. This fixture uses an unadmitted Node, so
the failures are not established §4.6.2 defects. The runner records them as
known gaps under investigation in #417: JSONL keeps `status: fail` with
`known_gap`, and the test fails if one starts to pass, so the gap is promoted
rather than hidden. The persistence assertion can only pass after quarantine,
so it is not independent evidence.
This proves scripted native cooperation, not real-provider drain or real TCP
disconnection. Verified quarantine reconciliation is not exercised and remains
an integration gap.

Cache tests compare the dispatched fingerprint and native received fingerprint
against an independent HMAC calculation, including result-only changes on both
sides of the configured byte bound. Separate `controller-policy` records check
real scheduler ranking and allocation/quarantine authority: affinity loses to
health/load/occupancy, exhausted capacity cannot be reused, and quarantine
survives claim release and authority restart. Those policy records do not claim
composed public scheduling or transport-failure recovery.

Native failure cases prove no retry after output commitment, unknown-code
rejection by the retry taxonomy, and unmanaged `no_alternative_node`. A durable
provisioned Node supplies the breaker target without admitting a managed Node.
Separate policy cases vary every retry safety gate. The explicitly labelled
`public-api-through-scripted-managed-runtime` lane uses the existing two-Node
Controller fixture to check successful retry, exhaustion, pinned execution
identity, prior allocation release before alternate scheduling, and one logical
terminal. It does not cross native workers. Native two-Node retry and failed
continuation without repeated client effects remain integration gaps.

JSONL reports fixture checks and labelled policy checks. Some standalone
negative controls and cache/disconnect preconditions still use ExUnit assertions;
their failures are visible in the test output, not fully enumerated in JSONL.
Do not treat the report as an exhaustive assertion manifest or aggregate pass.

Synthesized terminal usage checks require the selected attempt and logical
Request to retain the validated lower-bound count and `lower_bound` status
required by SPEC §§3.7, 7.2.9 and 7.5.3a. Do not change expected counts to zero
or convert a failure to a skip. Unknown runtime error codes must map to
`internal_error` under SPEC §3.7.1 in every mode.

Reasoning cases follow each endpoint's accepted input. A structured
`reasoning` object is an unsupported Chat parameter, and `reasoning.summary` is
an unsupported Responses parameter. An explicit effort (`reasoning_effort` or
`reasoning.effort`) returns `unsupported_reasoning_control`. The corpus runs
with tokenizer safe mode `reject`, and the rendered-effort route needs `off`, so
these cases prove the unavailable-route refusal, not a missing registration.
Positive rendered-effort application on a registered template is not part of
this fixture.

Hardware, OpenCode, Qwen, native-provider qualification,
production activation, and support claims remain outside this fixture.
