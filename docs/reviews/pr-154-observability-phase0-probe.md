# PR #154 review: Phase 0 observability probe pin

- **PR:** [#154](https://github.com/kapitan-ai/orchard/pull/154)
- **Branch:** `najibninaba/issue-115-phase0-probe-pin`
- **Reviewed commit:** `f6aa7e4dd0a77450a335e18afdff871f564424e3`
- **Comparison:** merge base with `origin/main` (`84dfdb7a`)
- **CI context:** Required Orchard validation was reported successful
- **Disposition:** **Blocked — do not merge**

## Summary

The PR has a useful narrow shape: it adds a versioned configuration, an
allowlisted result, typed `/v1/responses` terminal classification, optional
Controller-local persistence checking, and a producer/consumer pin template.
The current implementation can nevertheless produce false passing evidence,
leak sensitive values through allowlisted fields or transport, and crash instead
of emitting the promised safe result. CI success does not exercise the real
launcher, HTTP/TLS boundary, arbitrary SSE input, or endpoint-to-database path.

The most important red-green gaps are at the acceptance boundaries. Tests were
written for desired examples, but not for hostile or contradictory inputs: a
valid terminal beside a malformed terminal, an event/status mismatch, secret
content inside an allowed field, a client-visible completion beside a durable
failure, or a launcher connected to the wrong database.

## Blockers

### B1. The content-free result guarantee checks key names, not values

**References:**

- `scripts/support/observability_probe.exs:98-150`
- `scripts/support/observability_probe.exs:366-384`
- `scripts/support/observability_probe.exs:411-425`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:75-104`
- `openspec/changes/observability-phase0-probe/specs/observability-phase0-probe/spec.md:27-42`

`reject_forbidden_result_keys/1` scans only top-level key names. The two
attacker- or operator-controlled result values, `probe_id` and
`public_request_id`, accept any non-empty string with no grammar or length
bound. The result validator therefore accepts credentials, prompts, tenant
identifiers, DSNs, and stack-trace text when those values occupy allowed fields.

A focused reproduction on this commit returned `{:ok, result}` for:

```elixir
%{
  "probe_id" => "postgres://tenant:secret@host/db",
  "public_request_id" => "sk-secret-prompt-stacktrace",
  # remaining allowlisted fields valid
}
```

The current safety test inserts forbidden **fields** such as `prompt` and
`dsn`; it never inserts forbidden **values** into an allowlisted field. This
fails the review mandate that the result must never serialize those categories.

**Recommended fix:** give `probe_id` a closed, bounded operational identifier
grammar and validate `public_request_id` against Orchard's canonical bounded
Responses ID grammar before it enters a result. Refuse serialization otherwise.
Add table-driven tests placing representative prompt, response, credential,
tenant, DSN, and stack-trace markers in every allowed string field. Also test
maximum lengths.

### B2. Malformed or semantically contradictory terminal events can pass, and other malformed events crash

**References:**

- `scripts/support/observability_probe.exs:152-169`
- `scripts/support/observability_probe.exs:333-384`
- `scripts/support/observability_probe.exs:62-87`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:107-155`
- `apps/orchard_controller/lib/orchard/inference/responses_serializer.ex:108-178`
- `openspec/changes/observability-phase0-probe/specs/observability-phase0-probe/spec.md:44-67`

`decode_terminal_event/1` returns `[]` for a malformed terminal-looking block,
and `terminal_events/1` removes it with `flat_map`. A body containing one valid
`response.completed` block and a second malformed `response.completed` block
therefore has a computed terminal count of one and passes. This was reproduced
on the reviewed commit.

The classifier also never validates the terminal object shape or the relation
between event type and status. Reproductions showed:

- `response.completed` with no ID and no status passes;
- `response.completed` with status `failed` passes;
- `response.failed` with status `completed` is classified as a stable response
  failure rather than an invalid stream;
- `response: nil` passes a completed terminal with null ID/state;
- scalar/list response values can raise from `Access.get/3`;
- an integer response ID is accepted by classification and later makes
  `encode_result!/1` raise.

These are false positives at the artifact's core acceptance boundary. The
uncaught cases also violate the design promise that malformed responses produce
a stable failure classification without exception detail.

**Recommended fix:** parse terminal candidates without discarding invalid ones,
then require exactly one candidate and validate its complete closed shape:
matching SSE `event`/JSON `type`, response object, canonical ID, and legal
status for the event type (`completed` for `response.completed`; the documented
failed/incomplete statuses for `response.failed`). Convert all malformed binary
or field-type cases to `invalid_stream` before result encoding.

A red-green table should include valid-plus-malformed terminals, event/type
mismatch, missing/invalid IDs, missing/invalid statuses, completed/failed status
crossovers, null/string/list/integer response values, duplicate terminals, and
invalid UTF-8.

### B3. `controller_local` can report pass when the HTTP and durable outcomes disagree

**References:**

- `scripts/support/observability_probe.exs:171-189`
- `scripts/support/observability_probe.exs:291-331`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:159-191`
- `apps/orchard_controller/lib/orchard/requests/request.ex:25-42`
- `openspec/changes/observability-phase0-probe/design.md:42-65`
- `openspec/changes/observability-phase0-probe/specs/observability-phase0-probe/spec.md:69-85`

The durable validator checks only that one `state_transition` agrees with
`request.state`. On success, `maybe_validate_terminal/2` overwrites the count
and state while preserving the HTTP outcome and classification. A client-visible
`response.completed/completed` can therefore remain `pass/completed` when the
row and its sole terminal transition both say `failed`.

There is a second bypass: Controller-local validation runs only when
`public_request_id` is a binary. Because B2 allows a completed terminal with no
ID, that malformed completion passes and the catch-all clause returns it
without any database lookup.

The tests call `validate_terminal_record/2` in isolation and never combine HTTP
classification with contradictory durable evidence. The OpenSpec contract
itself encodes the problem by requiring the HTTP classification to be
preserved whenever the row and event agree internally, without requiring the
HTTP and durable outcomes to agree.

**Recommended fix:** define an explicit cross-plane mapping and enforce it before
preserving a classification. At minimum, HTTP completed must map to durable
`completed`; HTTP failed must not map to durable `completed`; and public
`incomplete` must map only to the documented durable cancelled/timed-out/
interrupted semantics. A missing canonical public ID must fail Controller-local
validation. Update the OpenSpec requirement and add combined integration tests
for matching and contradictory pairs.

### B4. Bearer credentials may be sent over unsafe transport or copied into the model field

**References:**

- `scripts/support/observability_probe.exs:98-110`
- `scripts/support/observability_probe.exs:242-270`
- `scripts/support/observability_probe.exs:481-490`
- `scripts/support/observability_probe.example.json:1-13`
- `docs/local-dev.md:73-92`
- `openspec/changes/observability-phase0-probe/design.md:1-18`

The URL validator accepts plaintext HTTP to any host, while the documentation
advertises use from a remote probe host. The request then sends the bearer
credential in an Authorization header. HTTPS requests do not supply an
explicit peer/hostname verification and CA policy to `:httpc`, and URL userinfo
is not rejected. The probe therefore does not enforce a trusted credential
destination.

Configuration also permits `model_env_var == credential_env_var`. In that case
the bearer credential is placed in the JSON `model` field as well as the
Authorization header, allowing it to enter request validation, logs, or durable
capture paths.

**Recommended fix:** restrict plaintext HTTP to loopback unless an explicit,
reviewed insecure-mode opt-in exists; define and configure peer/hostname
verification for HTTPS; reject userinfo and ambiguous authorities; require the
model and credential environment variable names to differ; and reject control
characters in header values. Add real HTTP/TLS tests that prove a request is not
sent for non-loopback plaintext, untrusted/mismatched TLS, URL userinfo,
identical environment names, or CR/LF credential values.

## Major findings

### M1. Controller-local execution is not bound to the database used by the probed Controller

**References:**

- `scripts/smoke-observability-probe.sh:8-14`
- `scripts/support/observability_probe.exs:279-290`
- `config/dev.exs:472-479`
- `config/runtime.exs:1129-1132`
- `docs/local-dev.md:87-92`

The wrapper runs source `mix run --no-start` in the default Mix environment.
That loads the dev Repo configuration (`PG*`, default database `orchard_dev`).
The packaged Controller's Repo uses release-time `DATABASE_URL`. Running this
source script on the same host does not import the running LaunchDaemon's
root-owned environment or prove that both processes target the same database.

The documentation currently treats “Controller host with direct access” as
sufficient. An operator may instead query a default dev database, another
reachable database, or fail before execution while believing the stronger mode
validated the serving Controller.

**Recommended fix:** support and document one verifiable topology: either an
explicit source-dev Controller configuration or a release-native command that
loads the packaged Controller's Repo configuration. Fail closed unless the
database identity can be correlated to the probed Controller. Add
production-shaped subprocess tests for correct, absent, wrong, and different
Repo targets.

### M2. Durable validation failure can construct a result that the result schema refuses

**References:**

- `scripts/support/observability_probe.exs:120-150`
- `scripts/support/observability_probe.exs:180-188`
- `scripts/support/observability_probe.exs:294-331`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:159-191`

On a missing terminal transition, `validate_terminal_record/2` returns the row's
state even when it is non-terminal. A reachable row in `running` state produces
`terminal_state: "running"`; `validate_result/1` rejects that value, so
`encode_result!/1` raises after `maybe_validate_terminal/2` has returned. This
was reproduced by validating the constructed failure shape.

The same area has no bounded retry/backoff or endpoint-level test showing the
row/event state visible at the instant the typed terminal is observed.

**Recommended fix:** on validation failure, emit `terminal_state` only when it
is a canonical durable terminal state; otherwise emit null. Define whether a
short bounded retry is required by the endpoint's persistence ordering. Test
every active `Request.state`, missing records, delayed terminal visibility, and
main/launcher encoding.

### M3. The executable boundary does not guarantee exactly one safe JSON record

**References:**

- `scripts/smoke-observability-probe.sh:11-14`
- `scripts/support/observability_probe.exs:62-87`
- `scripts/support/observability_probe.exs:206-270`
- `scripts/support/observability_probe.exs:279-331`
- `docs/local-dev.md:87-94`
- `openspec/changes/observability-phase0-probe/design.md:75-84`

The real command combines `mise`, Mix compilation/config evaluation, optional
Repo startup, HTTP applications, parsing, serialization, and `System.halt/1` in
one inherited stdout/stderr boundary. `main/1` contains no catch-all safety
boundary. Expected hostile response shapes already produce uncaught exceptions;
Mix/config/Repo/Logger output can also accompany or replace the result.

A missing-config smoke on the reviewed checkout happened to produce one stdout
JSON line, one sanitized stderr line, and exit 2. That one case is not evidence
for first-run compilation, HTTP failure, malformed response, Repo failure, or
injected internal failure. No test invokes `main/1` or the shell wrapper.

**Recommended fix:** run a precompiled pinned artifact or otherwise isolate
compilation/logging; catch all expected failures inside `main/1`; validate the
final record before emitting it; and reserve stdout for exactly one JSON line.
Add subprocess tests asserting exact stdout, sanitized stderr, and exit code for
usage, invalid config, pass, non-200, timeout/transport error, malformed SSE,
Repo failure, and internal failure.

### M4. The HTTP client buffers the entire response and does not establish the claimed SSE boundary

**References:**

- `scripts/support/observability_probe.exs:242-270`
- `scripts/support/observability_probe.exs:333-374`
- `apps/orchard_controller/lib/orchard/api/sse.ex:59-89`
- `openspec/changes/observability-phase0-probe/design.md:42-52`
- `openspec/changes/observability-phase0-probe/specs/observability-phase0-probe/spec.md:44-67`

`:httpc.request/4` returns a fully collected body. The probe does not observe
incremental delivery, terminal arrival before connection close, or bounded
stream progress. It also ignores `Content-Type`, places no maximum on the body
or event sizes, and accepts any HTTP 200 body containing recognized framing.
This is terminal-looking-body validation, not strong evidence that the endpoint
streamed SSE.

**Recommended fix:** use bounded incremental delivery, require
`text/event-stream`, reject redirects, cap headers/body/event sizes, and define
the required event sequence. Test delayed chunks, a terminal followed by a
connection that never closes, wrong content type, oversized input, redirect,
and a buffered non-SSE body.

### M5. Checked OpenSpec coverage does not exercise the production acceptance path

**References:**

- `openspec/changes/observability-phase0-probe/tasks.md:9-22`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:1-185`
- `apps/orchard_controller/lib/orchard/requests/request_server.ex:178-203`
- `apps/orchard_controller/lib/orchard/inference/request_orchestrator.ex:1276-1310`

The persisted test uses the canonical `state_transition` shape and does reach
Postgres through `Orchard.Requests`; it is not an invented event vocabulary.
However, it manually creates a request and transition, then calls only the
public pure validator. It does not issue `/v1/responses`, run the HTTP
classifier, invoke the private lookup path, or prove the real orchestrator/FSM
terminal write yields exactly one matching event.

The checked tasks therefore overstate evidence:

- **2.3:** HTTP and durable checks exist, but do not correlate outcomes.
- **3.1:** no invalid timeout boundary, size, URL authority, or result
  cross-field tests.
- **3.2:** no forbidden-value or malformed-plus-valid terminal tests.
- **3.3:** persisted fixture coverage exists, but not endpoint-to-Repo
  acceptance coverage.
- **4.3:** strict validation and CI pass, but neither exercises launcher,
  transport/TLS, or production-shaped Repo behavior.

**Recommended fix:** reopen the affected tasks or split them into explicit
implementation and acceptance-test tasks. Add a real streaming Controller test
that issues the request, parses its public ID, reads the exact resulting row and
ordered events, and passes those records through the complete Controller-local
classification path for completed and failure terminals.

### M6. The pin template is field-complete, but the runbook does not bind a run to the pinned bytes

**References:**

- `docs/pilots/README.md:15-41`
- `docs/pilots/issue-118-cp1-observability-probe-pin.example.json:1-12`
- `scripts/smoke-observability-probe.sh:8-14`

The example correctly includes `artifact_git_sha`, `config_sha256`,
`config_path`, result schema version, validation mode, producer/consumer issues,
and no literal credential. It is a template, not an actual #118 pin.

The launcher does not consume or validate the pin, and the runbook provides no
fail-closed preflight proving that HEAD equals `artifact_git_sha`, relevant
files are clean, the exact file passed to the launcher hashes to
`config_sha256`, and its `terminal_validation` matches the pin. The wrapper
always executes the current working-tree script. A dirty or different checkout
can therefore produce evidence labeled with an unrelated pin.

The config digest also binds only environment variable **names**. Changing the
resolved model leaves the digest and result unchanged, so model-specific pilot
evidence is not reproducible. Credentials must remain secret, but #118 still
needs a safe non-secret principal/provenance strategy if authorization identity
is material.

**Recommended fix:** provide a pin validator or exact portable preflight that
checks the closed pin schema, 40/64 lowercase-hex forms, exact HEAD, clean
artifact/launcher, exact config path and digest, validation-mode agreement, and
execution path before issuing a request. Record a safe non-secret model
artifact/version identifier outside the content-free result. Make conspicuous
that the placeholder values must be replaced.

## Minor findings

### m1. Runtime prerequisites and exit semantics are mislabeled or undocumented

**References:**

- `scripts/support/observability_probe.exs:62-94`
- `scripts/support/observability_probe.exs:191-204`
- `scripts/support/observability_probe.exs:242-290`
- `docs/local-dev.md:73-94`

Repo startup errors are reported as `invalid_config` with exit 2, while HTTP app
startup and other runtime failures may raise. Normal probe failures exit 1 and
usage exits 64, but the operator documentation does not state the contract.

**Recommended fix:** distinguish invalid configuration, runtime prerequisite,
transport/probe failure, and internal failure with stable classifications and
documented exit codes. Test each through the real launcher.

### m2. Configuration, timeout, and response sizes are unbounded

**References:**

- `scripts/support/observability_probe.exs:98-110`
- `scripts/support/observability_probe.exs:206-219`
- `scripts/support/observability_probe.exs:437-463`
- `scripts/support/observability_probe.exs:481-490`

Any positive timeout is accepted, `connect_timeout_ms` need not be less than or
equal to `request_timeout_ms`, and config/body/string sizes have no limits.
This permits accidental multi-day hangs, oversized retained identifiers, and
memory exhaustion from a large response.

**Recommended fix:** define practical min/max timeouts, their relation, config
and string bounds, and a response/event byte budget. Add boundary tests first.

### m3. The parser implements only a subset of SSE field semantics

**References:**

- `scripts/support/observability_probe.exs:333-374`
- `apps/orchard_controller/test/orchard/observability_probe_test.exs:107-155`

Only the first `event:` and `data:` line is used. Multiple `data:` lines are not
joined, repeated/conflicting fields are ignored after the first, and CR-only
framing is unsupported. A conflicting second data line can be silently ignored.

**Recommended fix:** implement a bounded SSE state machine or explicitly freeze
and test the narrower Orchard framing as part of the producer contract.

### m4. Operator secret handling encourages shell-history exposure

**References:**

- `docs/local-dev.md:73-86`
- `openspec/changes/observability-phase0-probe/proposal.md:38-43`

The example asks operators to paste a bearer token into an `export` command,
which many interactive shells retain in history. Environment inheritance can
also expose it to child processes.

**Recommended fix:** document a no-echo prompt or approved secret-manager/service
environment injection, and explicitly prohibit command-line arguments, shell
history, chat, and merged stdout/stderr evidence.

### m5. Cadence metadata is mandatory but unenforced

**References:**

- `scripts/support/observability_probe.exs:108-110`
- `scripts/support/observability_probe.example.json:12-13`
- `docs/pilots/README.md:9-14`

`cadence_notes` affects the config digest but is neither emitted nor enforced.
The actual cadence is consumer-owned, so notes can diverge from collected
timestamps without detection.

**Recommended fix:** define cadence as explicit consumer pin/runbook metadata
and validate it against retained run timestamps, or explain that this field is
non-enforced descriptive provenance.

## Nits

### n1. Valid-looking placeholder hashes are easy to adopt accidentally

**Reference:** `docs/pilots/issue-118-cp1-observability-probe-pin.example.json:5-11`

The example SHA and digest are syntactically valid repeated hex. Use conspicuous
replacement tokens in a non-valid template, or require a materialization command
that refuses placeholders.

## Missing tests a red-green cycle should have started with

1. Forbidden sensitive values in every allowed result string field.
2. Valid-plus-malformed, mismatched event/type/status, invalid ID/type, and
   invalid UTF-8 SSE terminals.
3. HTTP completed plus durable failed, HTTP failed plus durable completed, and
   the allowed incomplete-to-durable mappings.
4. A completed event with no public ID in `controller_local` mode.
5. Real launcher stdout/stderr/exit assertions for every failure class.
6. Real HTTP server cases for timeout, redirect, TLS verification, wrong content
   type, delayed chunks, never-closing streams, and body-size limits.
7. Endpoint-to-Repo coverage using the actual `/v1/responses` persistence path.
8. Correct versus wrong database identity in Controller-local mode.
9. Pin/checkout/config preflight, including dirty files and a changed model.
10. Timeout, identifier, config-file, response-body, and result cross-field
    boundaries.

## HTTP-only evidence strength

In its current form, `http_only` proves only that a completed HTTP 200 body
contains exactly one parser-recognized valid terminal **after invalid terminal
candidates have been discarded**. It does not prove incremental streaming,
SSE content type, complete event ordering, expected model output, durable
persistence, resolved model identity, credential principal, or Controller build
identity. Documentation and #118 acceptance criteria must not imply those
stronger claims.

## Residual risks for issue #118 CP1 pin

Even after this PR's defects are fixed, issue #118 must own and verify:

- actual producer commit and exact non-secret config bytes/digest;
- clean checkout and pin-to-execution preflight on every run;
- trusted transport/CA policy for the pilot topology;
- safe token injection, rotation, revocation, and process inheritance;
- stable model artifact/version and safe authorization provenance;
- clock synchronization, cadence, missed-run policy, and rollback criteria;
- schema-valid single-record result storage with stderr kept separate and
  sanitized;
- retention policy for the durable probe requests created by the cadence;
- explicit acknowledgement that `http_only` is terminal-observation evidence,
  not persistence or full inference-conformance evidence.

The absence of the consumer-owned actual #118 config, pin, and retained results
from this producer PR is expected and is not itself a defect.

## Validation performed during review

- `mise exec -- mix test apps/orchard_controller/test/orchard/observability_probe_test.exs`
  — **passed**, 12 tests.
- `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate observability-phase0-probe --type change --strict --no-interactive`
  — **passed** (with the repository's npm `allow-scripts` deprecation warning).
- Focused `mix run --no-start` reproductions — confirmed valid-plus-malformed
  terminal acceptance, wrong/missing terminal status/ID acceptance, scalar
  response crashes, forbidden values accepted in allowed result fields, and a
  non-terminal durable failure shape rejected by result validation.
- Real shell launcher with a missing config — produced exit 2, one JSON stdout
  line, and one sanitized stderr line; other launcher paths remain untested.

The full Elixir workflow was not rerun during this review; the PR's reported CI
success is noted above but does not cover the missing acceptance cases.
