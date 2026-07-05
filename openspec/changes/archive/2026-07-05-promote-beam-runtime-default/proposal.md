# Proposal: promote-beam-runtime-default

## Why

ADR 0001 accepted BEAM Distribution as the preferred first-party Controller-to-Node Agent transport but kept the BEAM adapter default-off, gated on accepted two-Mac smoke evidence and an explicit promotion decision.
That evidence now exists twice: the accepted 2026-06-27 run recorded in `docs/investigations/source-dev-beam-smoke-2026-06-27.md`, and a 2026-07-05 refresh on current `main` that proved transport, observation, admission, lifecycle, and multi-node scheduler explanations over real two-Mac BEAM distribution.
Source dev still defaults to the gRPC compatibility path, and BEAM mode currently leaves the legacy gRPC client surface configured, so the shipped defaults no longer match the accepted architecture direction.

## What Changes

- **BREAKING (source-dev workflow)**: `bin/dev-controller` and `bin/dev-node-agent` default to `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam`; the gRPC compatibility path requires explicit `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` opt-out.
- BEAM mode fully quiesces the legacy gRPC client surface: no default `Runtime client targets: 127.0.0.1:50071` is set when BEAM transport is selected (fixes the 2026-07-05 promotion-gate finding).
- `ORCHARD_RUNTIME_CLIENT_TARGETS` is demoted to a comparison-only compatibility surface in operator and contributor docs.
- `AGENTS.md`'s two-Mac source-dev pattern and `docs/local-dev.md` describe the BEAM surface as the primary path and the gRPC surface as compatibility opt-out.
- `SPEC.md` internal-communications language records BEAM Distribution as the default first-party source-dev Controller-to-Node Agent path with gRPC as a compatibility adapter, per ADR 0001.
- The promotion decision is recorded durably as a decision record update (ADR 0001 addendum or successor ADR).
- The fully implemented change packages `beam-first-runtime-endpoints` and `source-dev-beam-operating-model` are archived as part of acceptance, syncing their `runtime-endpoints` deltas into main specs.
- All-in-one `bin/dev` transport stance is decided in design: it currently rejects explicit BEAM mode and stays single-host gRPC loopback unless design concludes otherwise.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `runtime-endpoints`: default source-dev transport selection changes from gRPC compatibility to BEAM, and BEAM mode gains a legacy-surface quiescing requirement.

## Impact

- `bin/dev-controller`, `bin/dev-node-agent`, and the runtime endpoint transport resolution they configure.
- Contributor and operator docs: `AGENTS.md`, `docs/local-dev.md`, `docs/tooling.md` if command forms change.
- `SPEC.md` internal-comms/transport language.
- `docs/decisions/0001-runtime-endpoints-beam-first.md` (or a successor record).
- OpenSpec archive state for `beam-first-runtime-endpoints` and `source-dev-beam-operating-model`.
- SPEC.md impact: yes; the internal transport default language changes as described above.
