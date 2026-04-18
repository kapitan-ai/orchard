## Final Prompt
<taskname="Status TLS regression"/>
<task>Review uncommitted changes on `main` for the `:cacertfile` / `:transport_opts` fix in `apps/orchard_cli/lib/orchard_cli/commands/status.ex` and the regression-test strategy in `apps/orchard_cli/test/orchard_cli/commands/status_test.exs`. Determine whether current tests would fail if the bug is reintroduced, and recommend the minimal viable regression test approach with emphasis on correctness, regression protection, error handling, and testability.</task>

<architecture>
- `OrchardCLI.Commands.Status` builds endpoint candidates, probes `/health/ready`, and delegates HTTP to `default_request/2` (private) unless runtime overrides `:request`.
- TLS CA threading path is: `default_endpoint_candidates/0` or `endpoint_from_config/0` -> candidate `%{ca_certfile: ...}` -> `build_request_opts/1` -> `default_request/2` -> `maybe_add_ca_cert/2` -> `Req.request/2`.
- `OrchardCLI.Commands.Start` calls `Status.snapshot/1` during readiness polling, so status probe TLS failures also affect `orchardctl start` readiness behavior.
- Current status tests mostly inject `runtime[:request]` stubs, which bypass `default_request/2` and therefore bypass `maybe_add_ca_cert/2` option shaping.
- Existing CLI TLS test suite (`TLSTest`) shows current project conventions for integration-tagged tests (`@tag :integration`) and real OpenSSL-backed flows.</architecture>

<selected_context>
orchard/apps/orchard_cli/lib/orchard_cli/commands/status.ex: full implementation of probe flow, `default_request/2`, and `maybe_add_ca_cert/2` fix.
orchard/apps/orchard_cli/test/orchard_cli/commands/status_test.exs: current regression coverage and comment-only note replacing executable CA-transport assertion.
orchard/apps/orchard_cli/lib/orchard_cli/commands/start.ex: downstream consumer of `Status.snapshot/1` for readiness polling impact.
orchard/apps/orchard_cli/test/orchard_cli/commands/start_test.exs: existing readiness/error-path tests demonstrating how `status_runtime` is injected and what is/is not exercised.
orchard/apps/orchard_cli/test/orchard_cli/commands/tls_test.exs: integration test patterns in this app (real command execution, `@tag :integration`, cert lifecycle).
orchard/apps/orchard_cli/test/test_helper.exs: global test config (`ExUnit.start(exclude: [:integration])`) relevant to viability/cost of integration regression tests.
orchard/apps/orchard_cli/mix.exs: dependency context (`req ~> 0.5`) tied to option-key behavior.
_git_data/repos/orchard-f2deb629/2026-04-17/1608/diff/all.patch: complete uncommitted diff including unrelated files for review provenance.
_git_data/repos/orchard-f2deb629/2026-04-17/1608/diff/per-file/apps__orchard_cli__lib__orchard_cli__commands__status.ex.patch: focused status fix hunk.
_git_data/repos/orchard-f2deb629/2026-04-17/1608/diff/per-file/apps__orchard_cli__test__orchard_cli__commands__status_test.exs.patch: focused test-file hunk (comment-only regression note).
_git_data/repos/orchard-f2deb629/2026-04-17/1608/MAP.txt: snapshot metadata and changed-file index.
</selected_context>

<relationships>
- `Status.run/2` -> `run_status/1` -> `snapshot/1` -> `probe_candidates/2` -> `probe_candidate/2` -> `request_fn.(url, opts)`.
- Default path: `request_fn` defaults to private `default_request/2`; test path often overrides `request_fn`, skipping Req option construction.
- `default_request/2` constructs `connect_options` and calls `maybe_add_ca_cert/2`; this is the exact seam where incorrect key nesting (`:cacertfile` placement / `:transport_opts` key) causes regression.
- `Start.poll_ready/5` repeatedly calls `Status.snapshot/1`; TLS probe regressions propagate into startup timeout/error behavior.
- `TLSTest` demonstrates existing integration-test appetite and mechanics in `orchard_cli`, useful when weighing unit seam extraction vs small HTTPS integration regression test.
</relationships>

<ambiguities>
- It is not yet established whether maintainers prefer a pure unit regression test (via extracted/testable seam for Req options) or an `@tag :integration` HTTPS probe test that exercises Req+Finch+Mint end-to-end.
- Current selected tests do not directly prove final Req option shape, so review should explicitly decide if comment-only documentation is acceptable regression protection (likely insufficient) versus adding executable coverage.
</ambiguities>

## Selection
- Files: 11 total (11 full)
- Total tokens: 26795 (Auto view)
- Token breakdown: full 26795

### Files
### Selected Files
/Users/najib/Hacks/orchard/
└── apps/
    └── orchard_cli/
        ├── lib/
        │   └── orchard_cli/
        │       └── commands/
        │           ├── start.ex — 2,087 tokens (full)
        │           └── status.ex — 3,790 tokens (full)
        ├── test/
        │   ├── orchard_cli/
        │   │   └── commands/
        │   │       ├── start_test.exs — 4,395 tokens (full)
        │   │       ├── status_test.exs — 4,490 tokens (full)
        │   │       └── tls_test.exs — 5,069 tokens (full)
        │   └── test_helper.exs — 54 tokens (full)
        └── mix.exs — 238 tokens (full)
/Users/najib/Library/Application Support/RepoPrompt/Workspaces/Workspace-orchard-2F8EA405-65A2-413A-8A58-724D4CA9269B/_git_data/
└── repos/
    └── orchard-f2deb629/
        └── 2026-04-17/
            └── 1608/
                ├── diff/
                │   ├── per-file/
                │   │   ├── apps__orchard_cli__lib__orchard_cli__commands__status.ex.patch — 235 tokens (full)
                │   │   └── apps__orchard_cli__test__orchard_cli__commands__status_test.exs.patch — 274 tokens (full)
                │   └── all.patch — 4,600 tokens (full)
                └── MAP.txt — 1,563 tokens (full)


---

## Code Review

## Chat Send ✅
- **Chat**: `status-tls-regression-1B8B8B` | **Mode**: review

### Response
## Summary

These changes primarily correct the `orchardctl status` HTTPS probe so Req 0.5.x receives the local CA file under `connect_options[:transport_opts][:cacertfile]`, which also helps `orchardctl start` because it polls readiness through `Status.snapshot/1`. The `status.ex` fix itself looks correct, and the other code changes are formatting/comment-only, but the new “regression coverage” is only a note: the current tests still bypass `default_request/2`, so they would not fail if this CA-option bug were reintroduced.

## P1

- **`apps/orchard_cli/test/orchard_cli/commands/status_test.exs`** — The current suite does **not** protect the actual regression. All relevant tests inject `runtime[:request]`, which means they never execute `Status.default_request/2` or `maybe_add_ca_cert/2`; they only verify that a top-level `:ca_certfile` reaches the stub. If someone reverted the fix back to bare `:cacertfile` under `connect_options`, or misspelled `:transport_opts`, these tests would still pass while HTTPS-only packaged installs break again for both `orchardctl status` and `orchardctl start`.  
  **Suggestion:** add one executable regression test at the option-shaping seam. The minimal viable approach is to extract the Req option assembly into a small pure helper and assert it produces:
  ```elixir
  connect_options: [timeout: ..., transport_opts: [cacertfile: path]]
  ```
  and preserves existing nested transport opts if present. If you want stronger confidence later, add a single `@tag :integration` HTTPS probe test, but the extracted pure-helper test is the smallest reliable guard.


> 💡 Continue this review conversation with ask_oracle(chat_id: "status-tls-regression-1B8B8B", new_chat: false)