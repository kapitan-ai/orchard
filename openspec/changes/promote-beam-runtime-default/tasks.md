# Tasks: promote-beam-runtime-default

## 1. Transport Default Flip

- [x] 1.1 Default `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` to `beam` in `bin/dev-controller` when unset, preserving explicit `grpc` opt-out behavior.
  - Implemented in `bin/lib/source-dev-beam.sh` and exercised through `bin/dev-controller` in `scripts/test-source-dev-beam-bootstrap.sh` scenario I.
- [x] 1.2 Default `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` to `beam` in `bin/dev-node-agent` when unset, preserving explicit `grpc` opt-out behavior.
  - Implemented in `bin/lib/source-dev-beam.sh` and exercised through `bin/dev-node-agent` in `scripts/test-source-dev-beam-bootstrap.sh` scenario I.
- [x] 1.3 Keep all-in-one `bin/dev` on the single-host gRPC loopback default and verify it still rejects explicit BEAM mode with a clear error.
  - Verified by `scripts/test-source-dev-beam-bootstrap.sh` scenario H.
- [x] 1.4 Add or update tests covering default-BEAM resolution and explicit-gRPC opt-out for the split-role env surface.
  - Added default-BEAM helper assertions in `scripts/test-source-dev-beam-bootstrap.sh` scenario A.
  - Updated entrypoint default-BEAM assertions in scenario I and explicit-gRPC opt-out assertions in scenario J.

## 2. Legacy Surface Quiescing

- [x] 2.1 Stop configuring the implicit `127.0.0.1:50071` legacy runtime client target when the resolved transport is BEAM.
  - Implemented in `bin/dev-controller` by injecting the implicit target only after transport resolves to non-BEAM.
- [x] 2.2 Preserve explicitly set `ORCHARD_RUNTIME_CLIENT_TARGETS` as a gRPC comparison surface in BEAM mode.
  - Preserved by leaving explicit `ORCHARD_RUNTIME_CLIENT_TARGETS` untouched when BEAM is selected.
  - Verified by `dev.exs beam controller mode configures BEAM client and endpoint targets`.
- [x] 2.3 Add a regression test asserting no legacy gRPC runtime client target is configured in BEAM mode without explicit `ORCHARD_RUNTIME_CLIENT_TARGETS`.
  - Added `dev.exs beam controller mode without explicit legacy targets configures no gRPC targets`.
  - Added a shell assertion that default BEAM controller startup does not log `Runtime client targets: 127.0.0.1:50071`.

## 3. Docs And Contract Truth

- [x] 3.1 Update `docs/local-dev.md`: BEAM split-role mode becomes the documented default, gRPC becomes the explicit opt-out compatibility path, and `ORCHARD_RUNTIME_CLIENT_TARGETS` is described as comparison-only.
  - Updated the split-role sections, command examples, EPMD guidance, troubleshooting, and source-dev limitations.
- [x] 3.2 Update `AGENTS.md`'s two-Mac source-dev pattern to the BEAM surface (node names, cookie provisioning, `ORCHARD_BEAM_EPMD_PORT` guidance) with the gRPC pattern as opt-out.
  - Updated the Dev Environment two-Mac pattern with BEAM node names, shared cookie file, nonstandard EPMD guidance, and gRPC opt-out variables.
- [x] 3.3 Update `SPEC.md` internal-communications language: BEAM Distribution is the default first-party source-dev Controller-to-Node Agent path and gRPC is the compatibility adapter, per ADR 0001.
  - Updated the architecture summary and section 7.5 Runtime Endpoint and Internal Worker Interfaces language.
- [x] 3.4 Amend `docs/decisions/0001-runtime-endpoints-beam-first.md` with a dated promotion note recording the executed gate and its evidence.
  - Added the 2026-07-05 promotion status and evidence note citing the 2026-06-27 investigation plus the 2026-07-05 refresh.

## 4. Validation And Acceptance

- [x] 4.1 Run the full Elixir quality workflow from the umbrella root (format, compile --warnings-as-errors, credo --strict, dialyzer, test, cover).
  - Passed `mise exec -- mix format`.
  - Passed `mise exec -- mix compile --warnings-as-errors`.
  - Passed `mise exec -- mix credo --strict` with zero issues.
  - Passed `mise exec -- mix dialyzer`.
  - `ORCHARD_TEST_NODE_AGENT_PORT=50081 mise exec -- mix test` initially failed once because the worker venv entrypoint was missing before the suite materialized it.
  - The rerun of `ORCHARD_TEST_NODE_AGENT_PORT=50081 mise exec -- mix test` passed.
  - Passed `ORCHARD_TEST_NODE_AGENT_PORT=50081 mise exec -- mix test --cover`.
- [x] 4.2 Run strict OpenSpec validation for this change.
  - Passed `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate promote-beam-runtime-default --type change --strict --no-interactive`.
- [x] 4.3 Verify split-role BEAM default end-to-end on a single host (controller plus node-agent, default env) before PR handoff.
  - Verified source-dev split-role launch with no `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` set on either process.
  - Used `ORCHARD_BEAM_EPMD_PORT=43690` because default EPMD port `4369` failed local listener verification on this host before Mix started.
  - Verified node-agent and controller logs both reported `Runtime endpoint transport: beam`.
  - Verified the controller log did not report the implicit `Runtime client targets: 127.0.0.1:50071` line.
  - Verified an RPC probe through `Orchard.RuntimeEndpoint.BeamClient.status/1` returned a BEAM observation for `orchard_node_agent@127.0.0.1` with `health.ready == true`.
  - Verified cleanup left HTTP `4000`, gRPC `50071`, and nonstandard EPMD `43690` without source-dev listeners, and removed the generated same-host cookie.
- [ ] 4.4 After merge: archive `beam-first-runtime-endpoints`, `source-dev-beam-operating-model`, and then this change, running strict validation after each sync and reviewing generated main specs for placeholder prose.
