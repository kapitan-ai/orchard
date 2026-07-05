# Tasks: promote-beam-runtime-default

## 1. Transport Default Flip

- [ ] 1.1 Default `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` to `beam` in `bin/dev-controller` when unset, preserving explicit `grpc` opt-out behavior.
- [ ] 1.2 Default `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` to `beam` in `bin/dev-node-agent` when unset, preserving explicit `grpc` opt-out behavior.
- [ ] 1.3 Keep all-in-one `bin/dev` on the single-host gRPC loopback default and verify it still rejects explicit BEAM mode with a clear error.
- [ ] 1.4 Add or update tests covering default-BEAM resolution and explicit-gRPC opt-out for the split-role env surface.

## 2. Legacy Surface Quiescing

- [ ] 2.1 Stop configuring the implicit `127.0.0.1:50071` legacy runtime client target when the resolved transport is BEAM.
- [ ] 2.2 Preserve explicitly set `ORCHARD_RUNTIME_CLIENT_TARGETS` as a gRPC comparison surface in BEAM mode.
- [ ] 2.3 Add a regression test asserting no legacy gRPC runtime client target is configured in BEAM mode without explicit `ORCHARD_RUNTIME_CLIENT_TARGETS`.

## 3. Docs And Contract Truth

- [ ] 3.1 Update `docs/local-dev.md`: BEAM split-role mode becomes the documented default, gRPC becomes the explicit opt-out compatibility path, and `ORCHARD_RUNTIME_CLIENT_TARGETS` is described as comparison-only.
- [ ] 3.2 Update `AGENTS.md`'s two-Mac source-dev pattern to the BEAM surface (node names, cookie provisioning, `ORCHARD_BEAM_EPMD_PORT` guidance) with the gRPC pattern as opt-out.
- [ ] 3.3 Update `SPEC.md` internal-communications language: BEAM Distribution is the default first-party source-dev Controller-to-Node Agent path and gRPC is the compatibility adapter, per ADR 0001.
- [ ] 3.4 Amend `docs/decisions/0001-runtime-endpoints-beam-first.md` with a dated promotion note recording the executed gate and its evidence.

## 4. Validation And Acceptance

- [ ] 4.1 Run the full Elixir quality workflow from the umbrella root (format, compile --warnings-as-errors, credo --strict, dialyzer, test, cover).
- [ ] 4.2 Run strict OpenSpec validation for this change.
- [ ] 4.3 Verify split-role BEAM default end-to-end on a single host (controller plus node-agent, default env) before PR handoff.
- [ ] 4.4 After merge: archive `beam-first-runtime-endpoints`, `source-dev-beam-operating-model`, and then this change, running strict validation after each sync and reviewing generated main specs for placeholder prose.
