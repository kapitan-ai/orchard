## 1. Approved Contract

- [x] 1.1 Approve collection-time and outbound request allowlists that retain only the HTTP method.
- [x] 1.2 Approve validated first-party repo-relative filenames without source-code context.
- [x] 1.3 Approve static Product Version and build-provenance tags for controller and Node Agent events.
- [x] 1.4 Approve explicit non-expansion settings for tracing, Sentry Logs, source context, and dependency reporting.
- [x] 1.5 Approve explicit source-development and packaged smoke gates while keeping production traffic disabled; require IP-address storage prevention and `$user.geo.**` removal before either gate.

## 2. Red Tests And Request Boundary

- [x] 2.1 Add realistic Responses and Chat Completions full-event fixtures whose serialized envelopes fail while request body, header, cookie, URL, query, client-address, and machine-path sentinels survive.
- [x] 2.2 Add `Orchard.API.SentryRequestContext` tests proving the Plug stores only a valid HTTP method and never fetches or copies request data.
- [x] 2.3 Implement `Orchard.API.SentryRequestContext`, replace `Sentry.PlugContext` in the endpoint, and make `Orchard.SentryFilter` reconstruct request maps and structs from the method-only allowlist.
- [x] 2.4 Run the focused request-boundary and filter suites and confirm all request sentinels are absent from serialized envelopes.

## 3. Safe Stack Diagnostics

- [x] 3.1 Add failing stack-frame tests for known first-party relative paths, extractable absolute compiler paths, traversal, dependency, `_build`, source URL, and machine-specific paths.
- [x] 3.2 Implement first-party filename normalization for the four Orchard app `lib/` roots while filtering every other path-bearing field.
- [x] 3.3 Configure first-party OTP applications as in-app and explicitly disable source-code context.
- [x] 3.4 Run the focused stack and envelope suites and confirm no source snippets or absolute paths serialize.
- [x] 3.5 Add a real-crash regression proving a genuine BEAM app-relative `lib/` frame canonicalizes to its owning app root, plus hostile coverage for dependency-owned, unloaded, string, absent, deterministic-basename, and traversal frames.
- [x] 3.6 Canonicalize app-relative `lib/` filenames using runtime OTP application ownership of the frame's existing module, without creating atoms, and revalidate every canonicalized path against the approved-root path grammar.

## 4. Release Identity And Narrow SDK Defaults

- [x] 4.1 Add failing tests for controller, Node Agent, CLI, and unknown release-name mapping; canonical Product Version; release formatting; and static tags.
- [x] 4.2 Implement the shared Sentry release-metadata helper and wire `config/runtime.exs` to its release and tag outputs.
- [x] 4.3 Explicitly disable Sentry Logs, tracing, source-code context, and dependency reporting; retain deduplication; remove raw `orchard_node_id` from Logger metadata.
- [x] 4.4 Extend controller and Node Agent background-crash tests to assert static identity with no request context.
- [x] 4.5 Run focused metadata, application, Logger, and controlled-crash suites.

## 5. Wire Delivery And Failure Isolation

- [x] 5.1 Add a loopback Bandit receiver that captures the exact Sentry envelope body on an ephemeral port and returns a configurable status.
- [x] 5.2 Add a synchronous local-DSN delivery test that parses the received envelope and asserts safe diagnostics plus complete absence of request and machine sentinels.
- [x] 5.3 Add local transport-error coverage proving capture failure does not terminate or change the caller's result, and retain no-DSN handler coverage.
- [x] 5.4 Run the complete affected Sentry suite and verify the original deterministic red command now exits successfully.
- [x] 5.5 Rebuild the thread interface for non-exception crashes with hostile, malformed, non-redundancy, and envelope-serialization coverage, plus a real Logger-handler OTP crash delivered over the loopback receiver.
- [x] 5.6 Rebuild the nested `logger_metadata` extra from the curated allowlist and prove over a real Logger envelope that the curated keys survive while raw node identity, Logger level, and domain do not.
- [x] 5.7 Accept the exact `unknown` provenance sentinel in the build SHA and build date validators while keeping near-miss values filtered.
- [x] 5.8 Derive `orchard_thread_stack_hash` from retained thread frames so the pinned deduplication hash separates distinct thread-only crash sites, reject caller-supplied values, and cover equal/different stacks, shape, omission, and envelope minimization.
- [x] 5.9 Gate every rebuilt interface container on exact pinned SDK module identity, drop foreign or malformed interface structs instead of rebuilding their modules, and prove with loaded foreign fixture structs that sentinel-valued defaults never reach the envelope and serialization does not raise.
- [x] 5.10 Record the accepted frameless-event deduplication collapse in the spec and design risks, and cover it with a regression proving raw reasons are removed, no `orchard_thread_stack_hash` is emitted, and the filtered deduplication hashes match.

## 6. Validation And Handoff

- [x] 6.1 Run `mise exec -- mix format`.
- [x] 6.2 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 6.3 Run `mise exec -- mix credo --strict`.
- [x] 6.4 Run `mise exec -- mix dialyzer`.
- [x] 6.5 Run `mise exec -- mix test` and `mise exec -- mix test --cover`.
- [x] 6.6 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate harden-sentry-crash-egress --type change --strict --no-interactive` and `git diff --check`.
- [x] 6.7 Review the final diff against issue #114, this OpenSpec contract, and `SPEC.md` §9; report any packaged-smoke and Sentry-setting work that remains deferred.
- [x] 6.8 Verify project IP prevention and `$user.geo.**` removal, then complete the clean source-development controller and Node Agent stored-event review before merge; delete failed controlled issues and retain only synthetic smoke data.
