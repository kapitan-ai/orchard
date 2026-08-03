# Fix-pass design: PR #153 (health exposure split) and PR #154 (Phase 0 probe pin)

- **Scope:** design second opinion for the fix pass on the blocked reviews
  `docs/reviews/pr-153-health-exposure-split.md` (branch
  `najibninaba/health-exposure-split` @ `5a36a74`) and
  `docs/reviews/pr-154-observability-phase0-probe.md` (branch
  `najibninaba/issue-115-phase0-probe-pin` @ `f6aa7e4`).
- **Fixed constraints:** ADR 0016 is accepted. Public health bodies are
  status-only, Operator detail is authenticated with `no-store`, the staged
  predicate stays `orchard.readiness.legacy_m0.v1`, and no cache or
  compatibility shims. Exposure-before-§3.1 is settled and is not reopened
  here.
- **Method:** every fix lands red-first (failing test before mechanism), per
  the AGENTS.md Elixir workflow. No production code changes were made for this
  design.

---

## PR #153 — pilot health exposure split

### 1. Ordered blocker fix list

Order is dependency-driven: the fail-closed evaluation boundary (F1) is the
foundation; the Operator no-store guarantee (F2) leans on it; the CLI consumer
(F3) is independent and can run in parallel; OpenSpec reconciliation (F4) is
last because it records what the tests now prove.

#### F1 (Blocker) — bounded, fail-closed public readiness evaluation

**Mechanism.** Make `Orchard.API.HealthEvaluation.evaluate/0` total. Run the
unchanged `Readiness.status/0` in a supervised, unlinked task and normalize
every non-conforming outcome to one unavailable evaluation:

- Add a named `Task.Supervisor` (e.g. `Orchard.HealthTaskSupervisor`) to the
  controller supervision tree.
- `Task.Supervisor.async_nolink(sup, &readiness_impl().status/0)` then
  `Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill)`.
- Normalize:
  - `{:ok, {:ok, checks}}` → `%{ready?: true, checks: checks, reason: nil}`
  - `{:ok, {:error, reason, checks}}` → not ready, unchanged semantics
  - `{:ok, anything_else}` (malformed return), `{:exit, _}` (raise / exit /
    throw inside the task), or `nil` from timeout →
    `%{ready?: false, checks: [], reason: :readiness_unavailable}`
- `public_response/1` is already shape-total on `ready?`; with a total
  `evaluate/0` the public route can only render the two exact bodies.
- Timeout: a fixed module attribute (recommend 5_000 ms — below common LB
  probe deadlines of 10 s, above the DB checks' own timeouts). Overridable
  only through the test seam below, not a production config knob.
- Seam for fault injection: `readiness_impl` read from
  `Application.get_env(:orchard_controller, :health, [])`, defaulting to
  `Orchard.API.Readiness`. Document it as a test seam in the module doc so it
  does not grow into a second readiness authority (ADR 0016 forbids shims).

**What this deliberately does not do:** no rescue inside `Readiness` itself
(the predicate is contractually unchanged), no memoization of results, no
controller-level blanket rescue. Totality lives in one place. A rescue in
`HealthController.ready/2` would be redundant defense-in-depth and would fight
the ex_slop blanket-rescue check; skip it and note the residual (a failure in
`Phoenix.Controller.json/2` on a literal two-key map is not a realistic path).

`OperatorHealth.evaluate/0` already consumes `HealthEvaluation.evaluate/0`, so
the sanitized unavailable evaluation flows to the Operator body for free:
`reason: "readiness_unavailable"` with `ReadinessRemediation` handling the new
atom (add a bounded remediation entry). No exception detail ever reaches
either body.

#### F2 (Major) — `no-store` guaranteed at the pipeline boundary + real auth matrix

**Mechanism.** Move the header ahead of everything that can fail:

- Add a two-line plug (e.g. `Orchard.API.Plugs.NoStore`) as the **first** plug
  in the `:operator_api` pipeline in `router.ex`. Phoenix error rendering
  (`Phoenix.Endpoint.RenderErrors`) renders into the conn as it existed at
  raise time, so a header set in the pipeline survives auth failures and
  controller exceptions. Applying it to the whole operator scope is correct,
  not over-broad: scheduler explanations are operator diagnostics too and
  should never be cached.
- Keep the `put_resp_header` in `Ops.HealthController` or delete it; the plug
  is the guarantee. Recommend deleting to avoid a misleading duplicate.
- Test support: add a helper that mints a **real cluster-scoped operator**
  API client token (the current `operator_token!/1` calls
  `ensure_cluster_admin_access/1` and overstates coverage). If operator-role
  provisioning already exists for the `/ops/v1` boundary, reuse it; if not, a
  minimal fixture builder in `test/support` is in scope — a new provisioning
  feature is not.

#### F3 (Major) — CLI accepts only the two exact public pairs

**Mechanism.** In `apps/orchard_cli/lib/orchard_cli/commands/status.ex`:

- Replace `probe_candidate/2` + `validate_health_contract/1` acceptance with a
  closed table:
  - HTTP 200 **and** decoded body exactly `%{"status" => "ok"}` → ready
  - HTTP 503 **and** decoded body exactly `%{"status" => "error"}` → degraded
  - Any other HTTP status, any extra key, any status/body mismatch →
    `{:invalid_response, message}`; transport errors remain `:unreachable`.
  - Exactness check: `body == %{"status" => "ok"}` (map equality), not key
    probing.
- Delete the banner's consumption of `runtime`, `reason`, `remediation`,
  `transport`, `console`, and `license` from the public body
  (`render_banner/4`, `console_state_from_health/1`,
  `render_transport_lines/1`, `render_remediation_lines/1`,
  `remediation_for_body/1`, and the reason-keyed `local_remediation/1`
  dispatch). The credential-free banner becomes: local version (already
  labeled local), role, console URL **without a state claim**, API URL, and
  `ready`/`degraded`.
- Degraded hint: since the public body carries no reason, replace reason-keyed
  remediation with one fixed line pointing at the authenticated source, e.g.
  `Details: authenticated operators can run GET /ops/v1/health`. Keep the
  existing *local* lifecycle warnings (plists installed but not bootstrapped)
  — those come from local knowledge, not the public body, and remain honest.
- Remove rich-public-body fixtures from the shared test fixtures and every
  credential-free status test that normalizes them.

#### F4 (Major) — OpenSpec truthfulness

**Mechanism.** Spec and checkbox surgery, last in the sequence:

- `health-readiness-contract-prerequisite`: split the Console scenario that
  requires the future complete check set into an explicit stage-two scenario
  (or re-mark it `legacy_m0.v1`-scoped); add a stage-one scenario for
  invalid/exceptional/hung readiness → exact public 503.
- `pilot-health-exposure-split`: reopen tasks 2.4, 2.5, 3.1, 4.1–4.3; re-check
  each only when the corresponding red-green test from §2 exists and passes.
- Rerun both strict validations, and rerun `validate --all` after any main
  spec sync.

### 2. Tests that must fail first (red list)

All Controller tests go through the **full Endpoint** (`use OrchardWeb-style
ConnTest` with `@endpoint`), not `Router.call/2`, so Phoenix error rendering
is actually on the path. Confirm the test env is prod-shaped for errors
(`debug_errors: false`); if it is not, fix the test config first or the red
tests cannot go red for the right reason.

**F1 — public readiness (each red today):**

1. Readiness impl raises → `GET /health/ready` returns 503 with body exactly
   `{"status":"error"}` (today: Phoenix `{"errors":{"detail":...}}` 500).
2. Readiness impl exits; readiness impl throws → same exact 503.
3. Readiness impl returns a malformed term (`:ok`, `{:ok, nil, nil}`) → same.
4. Readiness impl sleeps forever → response arrives within the timeout budget
   (assert elapsed < timeout + margin), body exactly `{"status":"error"}`, and
   the spawned task is terminated (monitor the stub's pid from the test and
   assert `:DOWN`).
5. Sanity: ordinary pass/fail still return the exact bodies byte-for-byte
   (serialize and compare strings, guarding key-set drift).

**F2 — operator route (red today except the 401/403 basics):**

6. Syntactically valid but unknown bearer → 401 **and** `cache-control:
   no-store`.
7. Tenant token → 403 **and** `no-store` (header assertion is the new part).
8. Real operator-role token → 200, `no-store`, detailed body.
9. Ordinary readiness failure with admin token → 503, `no-store`, `reason` +
   bounded `remediation` present.
10. Readiness unavailable (injected raise) with operator token → 503,
    `no-store`, `reason: "readiness_unavailable"`, and the body contains no
    exception text (negative assertion on message fragments).

**F3 — CLI (red today):**

11. HTTP 503 + `{"status":"ok"}` body → invalid response, not ready.
12. HTTP 200 + `{"status":"ok","runtime":{...}}` (extra keys) → invalid.
13. HTTP 200 + `{"status":"error"}` → invalid (mismatched pair).
14. HTTP 404 + `{"status":"ok"}` valid JSON → invalid, not ready and not
    unreachable.
15. Degraded banner renders no transport/runtime/license/reason lines and does
    render the fixed operator-diagnostics hint.
16. Ready banner renders console URL without an enabled/disabled claim sourced
    from the response body.

### 3. Over-scoping risks

- **Readiness cache / circuit breaker / debounce.** ADR 0016 explicitly
  forbids readiness-only caches. The task boundary must evaluate fresh per
  request; resist "while we're here" rate protection.
- **Tri-state public status.** The public contract is binary. Do not surface
  `readiness_unavailable` publicly; it is an Operator-only reason.
- **Configurable timeout knob.** A production config option invites operators
  to tune away the fail-closed property. Fixed constant + test seam only.
- **Touching the `Readiness` predicate.** Any "improvement" to the four legacy
  checks is stage-two work and breaks the ADR's labeling story.
- **CLI operator authentication.** Building token-bearing `orchardctl status`
  now is a feature, not a fix. Credential-free bounded loss is the accepted
  contract (ADR 0016).
- **Generic no-store on all API pipelines.** Scope to the operator pipeline;
  tenant-facing caching semantics are a separate discussion.

### 4. Explicit deferrals that keep the pilot honest

- Complete §3.1 aggregate (cache hydration, conditional leadership) — already
  deferred by ADR 0016; the labeled `legacy_m0.v1` identifier carries the
  honesty.
- Authenticated `orchardctl` operator diagnostics subcommand — defer; the
  runbook path is `curl` with an operator token.
- Public endpoint rate limiting / network exposure — operational controls,
  documented as residual risk, outside this PR.
- Console state in the CLI banner from local install config — defer; showing
  the URL without a state claim is honest and cheap.
- Finer-grained unavailable reasons (distinguishing timeout vs crash in the
  Operator body) — one sanitized reason atom is enough for the pilot; detail
  granularity can follow the complete aggregate.

### 5. Where the review is wrong or overstated

Nothing in the #153 review is wrong; two calibration notes:

- **"Terminate timed-out work"** is right as stated, but note the readiness DB
  checks already carry their own timeouts. The task boundary is a backstop,
  and `:brutal_kill` on read-only checks is safe; do not build graceful
  drain machinery for it.
- **The Operator no-store finding** implies normalizing every authorized
  evaluation failure. With F1 making `HealthEvaluation` total and the existing
  rescues around the runtime/license probes, the pipeline plug is sufficient;
  a second normalization layer inside `OperatorHealth` is not needed.

---

## PR #154 — Phase 0 observability probe pin

### 1. Ordered blocker fix list

Order: B2 first (terminal parsing is the semantic foundation), then B1 (value
grammars reuse the canonical ID decision), then B3 (cross-plane mapping sits
on both), then B4 (transport, independent), then majors. OpenSpec/task
reconciliation (M5) is last.

#### P1 = B2 — strict, closed terminal parsing

**Mechanism.** Rework `terminal_events/1` and `decode_terminal_event/1` so
invalid candidates are counted, not discarded:

- Classify each blank-line-delimited block as `{:valid, event}`,
  `{:invalid, reason}`, or `:not_terminal`. A block is a *terminal candidate*
  if its SSE `event:` field **or** its decoded `data.type` is
  `response.completed` / `response.failed`.
- A candidate is valid only if the complete closed shape holds: SSE `event`
  equals JSON `type`; `response` is a map; `response["id"]` matches the
  canonical grammar (below); `response["status"]` is legal for the event type
  — `"completed"` for `response.completed`, and for `response.failed` exactly
  the failure statuses `Orchard.Inference.ResponsesSerializer` emits (freeze
  the accepted set against `responses_serializer.ex:108-178` as the producer
  contract and cite it in the test module).
- Classification passes only when there is **exactly one valid candidate and
  zero invalid candidates**. Duplicates, valid-plus-malformed, mismatches,
  crossovers (`response.failed` + `status: "completed"`), null/scalar/list
  `response`, integer IDs, and invalid UTF-8 all map to `invalid_stream`.
- Make classification total with explicit type guards (`is_map/1`,
  `String.valid?/1`) rather than a blanket rescue, so ex_slop stays clean and
  no `Access.get/3` crash path remains.

#### P2 = B1 — value-level content-free guarantees

**Mechanism.** Closed grammars on the two operator/attacker-influenced string
fields, enforced at construction **and** in `validate_result/1`:

- `probe_id`: closed operational slug, e.g.
  `^[a-z0-9][a-z0-9-]{0,62}$` (lowercase alphanumeric + hyphen, ≤ 64 bytes).
  Enforce identically in `validate_config/1` so a bad config never reaches a
  result.
- `public_request_id`: the canonical Responses grammar. Orchard generates
  `"resp_" <> Ecto.UUID.generate()`
  (`responses_request_normalizer.ex:11`), so validate
  `^resp_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
  A terminal whose ID fails the grammar is an invalid candidate under P1
  (`invalid_stream`), so a non-canonical ID never enters a result.
- Keep the forbidden-key-fragment scan as a secondary net; it is no longer the
  load-bearing guarantee.

#### P3 = B3 — cross-plane agreement in `controller_local`

**Mechanism.** Define the mapping and enforce it before preserving any HTTP
classification:

- Pass requires **all** of: HTTP classification `completed`, canonical
  `public_request_id` present, durable `request.state == :completed`, and
  exactly one matching terminal `state_transition`.
- HTTP `completed` + durable anything-else → `terminal_validation_failed`.
- HTTP `response_failed` + durable `completed` → `terminal_validation_failed`
  (a durable success behind a client-visible failure is exactly the
  observability defect Phase 0 exists to catch).
- Remove the silent catch-all: in `controller_local` mode a missing or
  non-binary `public_request_id` is `terminal_validation_failed`, never a
  skip. (P1 already prevents the no-ID completed terminal from being
  classified `pass`, so this clause is belt-and-braces.)
- Update the OpenSpec requirement to state cross-plane agreement explicitly,
  replacing the internal-consistency-only wording.

#### P4 = B4 — credential destination hardening

**Mechanism.** All in `validate_config/1` / `request/3`:

- `http` scheme allowed only for loopback hosts (`127.0.0.1`, `::1`,
  `localhost`); everything else requires `https`. No general insecure-mode
  flag in Phase 0.
- Reject URL userinfo and empty/ambiguous authorities.
- Explicit `:httpc` ssl options: `verify: :verify_peer`, CAs from
  `:public_key.cacerts_get()` plus an optional `ca_certfile` config key (the
  Orchard self-signed `/ca.crt` topology needs it — mirror the CLI's
  `ca_certfile` pattern), `customize_hostname_check` with the HTTPS match
  fun, and `autoredirect: false`. Do not rely on OTP-version-dependent ssl
  defaults; pin the options regardless.
- Require `model_env_var != credential_env_var`; reject control characters
  (CR/LF) and unbounded lengths in the resolved model and credential values
  before any request is constructed.
- Config schema changes (adding `ca_certfile`) are fine without a version
  bump: schema_version 1 has never merged.

#### P5 = M2 — result-shape totality on durable failure

Emit `terminal_state` only when the observed durable state is in
`@terminal_states`; otherwise `null`. This removes the reproduced
`running`-state `encode_result!/1` raise. Decide bounded retry by reading the
persistence ordering in `request_server.ex` / `request_orchestrator.ex`: if
the terminal transition can commit after the SSE terminal flush, add one
bounded retry (≤ 2 s total, fixed interval, counted in the test); if the
write strictly precedes the flush, add no retry and record that fact in the
OpenSpec design doc.

#### P6 = M3 + m1 — one safe JSON line at the executable boundary

- `run/1` returns tagged outcomes for every expected failure class; add an
  `internal_failure` classification for the truly unexpected, produced by one
  narrow boundary rescue in `main/1` with a scoped credo disable and
  rationale (a CLI top-level boundary is the legitimate place for it).
- Validate the final record before printing; stdout carries exactly one JSON
  line, everything else to stderr (Logger to stderr in the script config).
- Wrapper: `mix compile` (stdout suppressed or redirected) then
  `mix run --no-compile --no-start`, so first-run compilation noise cannot
  contaminate the record.
- Document the exit-code contract (0 pass, 1 probe fail, 2 invalid config,
  64 usage, plus runtime-prerequisite as its own documented code) in
  `docs/local-dev.md`.

#### P7 = M4-lite — fail-closed parse hardening, not a streaming client

- Require `content-type: text/event-stream` on the 200 response.
- Cap the buffered body (e.g. 1 MiB) and per-event size; oversize →
  `invalid_stream`.
- Redirects already rejected via `autoredirect: false` (P4).
- Freeze the narrow Orchard SSE framing (single `event:`/`data:` line per
  event, as `sse.ex` emits) as an explicit producer contract with tests,
  answering m3 without a general SSE state machine.
- Relabel the evidence: `http_only` proves "exactly one valid terminal in a
  complete, bounded, correctly-typed buffered response". Incremental
  streaming observation is **deferred** (see §4).

#### P8 = M1 — verifiable database identity for `controller_local`

Require an explicit `database_url_env_var` config key when
`terminal_validation == "controller_local"`; configure the Repo from that DSN
instead of inheriting Mix dev config. Fail closed when unset. Document that
the operator supplies the packaged Controller's `DATABASE_URL`.

#### P9 = M6 + n1 — pin preflight and template hygiene

- Replace the plausible repeated-hex placeholders in the example pin with
  non-hex tokens (`"REPLACE_WITH_ARTIFACT_SHA"`) so a copied template cannot
  validate.
- Add a small preflight (script or exact runbook commands): pin schema check,
  40/64 lowercase-hex forms, `git rev-parse HEAD` equals `artifact_git_sha`,
  clean status for the probe script and wrapper paths, `shasum -a 256` of the
  exact config path equals `config_sha256`, `terminal_validation` agreement,
  refuse placeholder tokens.
- Record the resolved model identifier (bounded grammar, non-secret) in the
  **pin**, not the result, so model changes are visible in provenance while
  the result stays content-free.

#### P10 = M5 — acceptance path and task truthfulness

Add one real endpoint-to-Repo acceptance test in the controller suite: issue
`POST /v1/responses` (streaming) through the endpoint, capture the actual SSE
body, run it through `classify_http_result/2`, read the real row and ordered
events by the parsed public ID, and run the full `controller_local`
validation — once for a completed terminal and once for a failure terminal.
Then reopen/narrow tasks 2.3, 3.1–3.3, 4.3 and re-check them against the red
list below.

### 2. Tests that must fail first (red list)

**P1/B2 — classifier table (each reproduced red on `f6aa7e4`):**

1. One valid `response.completed` + one malformed `response.completed` block →
   `invalid_stream` (today: pass).
2. `response.completed` with missing ID / missing status → `invalid_stream`.
3. `response.completed` with `status: "failed"`; `response.failed` with
   `status: "completed"` → `invalid_stream`.
4. `response: nil` / scalar / list / integer ID → `invalid_stream`, no raise.
5. Duplicate valid terminals; invalid UTF-8 body → `invalid_stream`, no raise.
6. SSE `event:` disagreeing with JSON `type` → `invalid_stream`.

**P2/B1 — value table:**

7. DSN, `sk-`-style token, prompt text, tenant slug, and stack-trace text in
   `probe_id` and `public_request_id` → result validation refuses (today:
   accepted).
8. Over-length values in every string field → refused.
9. Non-canonical `public_request_id` (`resp_` missing, uppercase, non-UUID) →
   never serialized.

**P3/B3 — cross-plane table:**

10. HTTP completed + durable row/event both `failed` → fail,
    `terminal_validation_failed` (today: pass).
11. HTTP `response_failed` + durable `completed` → fail.
12. Completed terminal without public ID in `controller_local` → fail (today:
    silently skips the DB check).

**P4/B4 — transport/config:**

13. Non-loopback `http` URL, URL userinfo, `model_env_var ==
    credential_env_var`, CRLF in credential → config refused before any
    request (assert via a request-capturing seam that no request was built).
14. TLS options assertion: the captured `:httpc` options include
    `verify_peer`, CA source, hostname check, `autoredirect: false`. Plus one
    integration test against a local self-signed listener without the CA
    configured → transport error, no request completes.

**P5–P7 — boundary and launcher:**

15. Reachable row in `running` state → result encodes with
    `terminal_state: null`, no raise (today: `encode_result!/1` raises).
16. Subprocess launcher tests (`System.cmd` on the wrapper) asserting exact
    stdout line-count, sanitized stderr, and exit code for: usage, invalid
    config, transport error (closed port), malformed SSE and pass (loopback
    stub server in the test), and Repo failure (unreachable DSN).
17. Wrong `content-type` on 200; body over the byte cap → `invalid_stream`.

**P10 — acceptance:**

18. Endpoint-to-Repo completed and failure runs as described above; the
    failure run must show the cross-plane mapping, not internal consistency
    only.

### 3. Over-scoping risks

- **Full SSE state machine / incremental streaming client.** The biggest
  trap. Real incremental observation means replacing `:httpc`'s synchronous
  API (async httpc or Mint), buffering discipline, and stall detection —
  a rewrite of the probe's transport for evidence Phase 0 does not claim.
  Fail-closed parse + honest evidence labeling (P7) is the right cut; the
  review's own "HTTP-only evidence strength" section supplies the labeling
  language.
- **Precompiled artifact distribution.** Building a release/escript pipeline
  for one pilot script is packaging work; compile-then-run with stdout
  discipline (P6) achieves the single-JSON-line contract.
- **Full TLS conformance matrix.** Hostname-mismatch, chain-depth, and
  revocation cases balloon. Options-assertion plus one negative integration
  test is proportionate; the rest is OTP's job.
- **Cryptographic DB↔Controller identity correlation.** See §5 — explicit
  DSN plus the existing missing-row fail-closed behavior is enough for
  Phase 0.
- **General retry/backoff framework** for durable visibility. One bounded,
  ordering-justified retry at most (P5).
- **Building #118's consumer tooling in this PR.** The actual pin, cadence
  enforcement, retention, and rotation are consumer-owned (the review agrees);
  this PR ships the producer contract, preflight, and honest template only.

### 4. Explicit deferrals that keep the pilot pin honest

- **Incremental SSE streaming evidence** → deferred to the acceptance-harness
  workstream (`issue-115-observability-acceptance-harness`). Honest because
  the result schema, docs, and #118 acceptance language say buffered
  terminal-observation, nothing more.
- **Release-native `controller_local` command** → deferred; the explicit-DSN
  requirement (P8) plus docs keeps the mode truthful about what it queried.
- **Automated cadence enforcement (m5)** → declare `cadence_notes`
  non-enforced descriptive provenance in the runbook; enforcement belongs to
  the consumer pin.
- **Secret-manager integration (m4)** → document a no-echo prompt
  (`read -s`) and prohibit argv/history/merged-stream evidence; tooling
  integration deferred.
- **Model identity inside the result** → deferred permanently by design; it
  lives in the pin (P9), which is the reproducibility surface.
- Each deferral is visible in the pin or runbook text, so the #118 evidence
  reader sees exactly what was and was not proven.

### 5. Where the review is wrong or overstated

- **M1's false-pass framing is overstated.** A launcher pointed at the wrong
  database cannot fabricate a pass: the probe's `public_request_id` row does
  not exist there, so `controller_local` fails closed today (`nil` →
  `terminal_validation_failed`). The genuine defects are (a) the no-ID bypass
  — which is B3/P3, not a database problem — and (b) an operator silently
  querying dev config and misreading a *failure*. P8's explicit DSN plus docs
  fixes (b); "correlate database identity to the probed Controller" beyond
  that is not needed for Phase 0 and should not gate the fix pass.
- **M4's "use bounded incremental delivery" should not be taken literally.**
  Adopt the content-type/size/redirect hardening, decline the streaming
  client, and land the evidence relabeling instead (P7, §3). The review
  itself provides the fallback position.
- **B4 TLS severity depends on OTP defaults** (OTP 26+ ssl clients default to
  `verify_peer`), so the wire exposure may be narrower than the text implies —
  but the fix is identical either way: pin explicit options and stop
  depending on runtime defaults. No change to the fix list.
- Everything else — B1, B2, B3, M2, M3, M5, M6, the minors — is accurate and
  was reproduced or is directly visible in the reviewed source.

---

## Cross-cutting execution notes

- Both branches: run the full Elixir workflow (`format`, `compile
  --warnings-as-errors`, `credo --strict` with ex_slop/ex_dna clean,
  `dialyzer`, `test`, `test --cover`) before handoff; new modules
  (`NoStore` plug, task supervisor child, preflight script) need direct
  coverage.
- OpenSpec: rerun strict validation for `pilot-health-exposure-split`,
  `health-readiness-contract-prerequisite`, and `observability-phase0-probe`
  after the spec-delta edits, and treat checkbox state as claims that the red
  list must back.
- The two fix passes are independent; nothing in #154 depends on #153's
  health changes. They can proceed in parallel worktrees.
