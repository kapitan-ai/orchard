## 1. Source-dev Configuration Surface

- [ ] 1.1 Add source-dev parsing for `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` with explicit `grpc` and `beam` modes.
- [ ] 1.2 Add source-dev parsing for `ORCHARD_RUNTIME_ENDPOINT_TARGETS` as BEAM node-name targets when transport is `beam`.
- [ ] 1.3 Keep `ORCHARD_RUNTIME_CLIENT_TARGETS` scoped to gRPC Compatibility Adapter `host:port` targets.
- [ ] 1.4 Add source-dev parsing for `ORCHARD_BEAM_NODE_NAME`, `ORCHARD_BEAM_COOKIE_FILE`, `ORCHARD_BEAM_DIST_PORT_MIN`, `ORCHARD_BEAM_DIST_PORT_MAX`, and `ORCHARD_BEAM_EPMD_PORT`.
- [ ] 1.5 Add validation that Source-dev BEAM target host parts are IP literals and reject hostname targets for this slice.

## 2. Split-role BEAM Bootstrap

- [ ] 2.1 Add a shared source-dev shell bootstrap helper for BEAM launch flags used by `bin/dev-controller` and `bin/dev-node-agent`.
- [ ] 2.2 Update `bin/dev-controller` to start as a named distributed BEAM node when Source-dev BEAM mode is selected.
- [ ] 2.3 Update `bin/dev-node-agent` to start as a named distributed BEAM node when Source-dev BEAM mode is selected.
- [ ] 2.4 Preserve all-in-one `bin/dev` on the gRPC compatibility default in this implementation slice.
- [ ] 2.5 Print non-secret startup diagnostics for BEAM node name, cookie file path, EPMD port, and distribution port range.
- [ ] 2.6 Defer `orchardctl env init` rendering of the Source-dev BEAM env surface to a separate CLI scaffolding change; this implementation slice must not imply that `orchardctl env init` emits BEAM variables.

## 3. Cookie And Distribution Networking

- [ ] 3.1 Implement same-host source-dev creation of `tmp/dev/beam.cookie` when BEAM mode is selected and no explicit cookie file exists.
- [ ] 3.2 Validate that BEAM cookie files exist, are non-empty, and have mode `0600` or stricter before Runtime Endpoint work is attempted.
- [ ] 3.3 Ensure cookie contents are never printed in logs, generated templates, diagnostics, or startup output.
- [ ] 3.4 Apply `ORCHARD_BEAM_EPMD_PORT` with default `4369` for Source-dev BEAM launches.
- [ ] 3.5 Apply `ORCHARD_BEAM_DIST_PORT_MIN` and `ORCHARD_BEAM_DIST_PORT_MAX` as bounded distribution listener settings for Source-dev BEAM launches.
- [ ] 3.6 Reject invalid distribution port ranges before Runtime Endpoint work is attempted.

## 4. Runtime Endpoint Wiring And Failure Behavior

- [ ] 4.1 Wire Source-dev BEAM mode to `Orchard.RuntimeEndpoint.BeamClient` through Runtime Endpoint Interface configuration.
- [ ] 4.2 Wire parsed BEAM targets into `:orchard_controller, :inference, :runtime_endpoint_targets` without reading `ORCHARD_RUNTIME_CLIENT_TARGETS`.
- [ ] 4.3 Preserve gRPC Compatibility Adapter configuration when `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` is unset or explicitly `grpc`.
- [ ] 4.4 Ensure BEAM configuration, guardrail, connection, target identity, and Runtime Endpoint RPC failures do not automatically retry the same request through gRPC.
- [ ] 4.5 Ensure Console Nodes diagnostics use the active Runtime Endpoint target list and BEAM client when BEAM mode is selected.

## 5. Documentation And Smoke Evidence

- [ ] 5.1 Update `docs/local-dev.md` with the implemented Source-dev BEAM split-role launch commands and troubleshooting guidance.
- [ ] 5.2 Document two-Mac cookie provisioning and verification without committing cookie material.
- [ ] 5.3 Document EPMD and bounded distribution port reachability requirements for the two-Mac smoke.
- [ ] 5.4 Run the two-Mac Source-dev BEAM smoke and record durable evidence in `docs/investigations/source-dev-beam-smoke-<date>.md` with date, commit, sanitized hosts, commands, controller and node-agent BEAM node names, and remote Runtime Endpoint RPC evidence.
- [ ] 5.5 Record Console Nodes reachability for local and remote Node Agents, `GET /v1/models` returning `200`, and `POST /v1/chat/completions` completing through Console Playground or an equivalent API request.
- [ ] 5.6 Defer any source-dev default promotion or all-in-one `bin/dev` BEAM default change to a separate OpenSpec change after the smoke evidence gate passes.

## 6. Tests And Validation

- [ ] 6.1 Add unit tests for source-dev Runtime Endpoint transport parsing and BEAM target parsing.
- [ ] 6.2 Add tests that `ORCHARD_RUNTIME_CLIENT_TARGETS` remains gRPC compatibility-only and is not interpreted as a BEAM target source.
- [ ] 6.3 Add tests for IP-literal BEAM target host validation and hostname rejection.
- [ ] 6.4 Add tests for cookie file existence, non-empty content, strict permissions, and secret-safe diagnostics.
- [ ] 6.5 Add tests for invalid EPMD or distribution port configuration.
- [ ] 6.6 Add tests proving BEAM mode failures do not automatically fall back to gRPC for the same request.
- [ ] 6.7 Add split-role bootstrap tests or smoke harness coverage for named distributed BEAM nodes where practical.
- [ ] 6.8 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate source-dev-beam-operating-model --type change --strict --no-interactive`.
- [ ] 6.9 Run `mise exec -- mix format`.
- [ ] 6.10 Run `mise exec -- mix compile --warnings-as-errors`.
- [ ] 6.11 Run `mise exec -- mix credo --strict`.
- [ ] 6.12 Run `mise exec -- mix dialyzer`.
- [ ] 6.13 Run `mise exec -- mix test`.
- [ ] 6.14 Run `mise exec -- mix test --cover`.
- [ ] 6.15 After spec sync or archive, review generated specs for placeholder prose such as `Purpose TBD`.
