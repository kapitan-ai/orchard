# Design: promote-beam-runtime-default

## Context

ADR 0001 accepted BEAM Distribution as the preferred first-party Controller-to-Node Agent transport with the adapter default-off behind a promotion gate.
The gate's evidence exists twice: the accepted 2026-06-27 two-Mac run in `docs/investigations/source-dev-beam-smoke-2026-06-27.md`, and the 2026-07-05 refresh on `main` 3454423 that proved BEAM transport, observation, admission, lifecycle actions, and multi-node scheduler explanations against a real remote node-agent.
The refresh also produced the one open finding: `bin/dev-controller` in BEAM mode still sets the implicit legacy `Runtime client targets: 127.0.0.1:50071`.
Two fully implemented change packages (`beam-first-runtime-endpoints`, `source-dev-beam-operating-model`) await archive; their `runtime-endpoints` deltas are not yet synced into main specs.
Constraints: BEAM mode fails visibly by design with no automatic gRPC fallback; production BEAM distribution guardrails from ADR 0001 (identity-bound, network-restricted, first-party only) are unchanged by this promotion.

## Goals / Non-Goals

**Goals:**
- Make BEAM the default split-role source-dev transport with gRPC as explicit opt-out.
- Fully quiesce the implicit legacy gRPC client target in BEAM mode.
- Bring contributor docs, SPEC internal-comms language, and decision records in line with the promoted default.
- Archive both completed BEAM packages, syncing their deltas to main specs.

**Non-Goals:**
- Packaged runtime transport changes (packaged builds keep their current path; promotion there is a later decision).
- Removing the gRPC compatibility adapter or `ORCHARD_RUNTIME_CLIENT_TARGETS` (explicit comparison use stays supported).
- BEAM support in all-in-one `bin/dev` (single-VM topology has no cross-host transport need).
- Production BEAM guardrail changes, epmd port policy changes, or cookie management tooling (`orchardctl env init` scaffolding stays deferred).

## Decisions

- **Default flip location: the dev scripts, not config defaults.**
  `bin/dev-controller` and `bin/dev-node-agent` resolve `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT` and default it to `beam` when unset, keeping the config layer's explicit-selection semantics intact.
  Alternative considered: flipping the default inside `config/dev.exs`; rejected because the scripts already own the split-role env surface (BEAM node names, EPMD port, cookie paths) and all-in-one `bin/dev` must keep a different default.
- **Quiescing: suppress the implicit gRPC target when transport resolves to BEAM.**
  The controller script and runtime config stop injecting `127.0.0.1:50071` as a default runtime client target in BEAM mode; an explicitly set `ORCHARD_RUNTIME_CLIENT_TARGETS` still configures the comparison surface.
  Alternative considered: hard-rejecting `ORCHARD_RUNTIME_CLIENT_TARGETS` in BEAM mode; rejected because `docs/local-dev.md` deliberately documents side-by-side comparison.
- **All-in-one `bin/dev` keeps gRPC loopback and keeps rejecting explicit BEAM mode.**
  A single VM hosting controller and node-agent gains nothing from distribution; the rejection preserves the fail-visible contract.
- **Decision record: amend ADR 0001 status rather than a successor ADR.**
  The promotion is the completion of ADR 0001's own gate, not a new boundary; a dated promotion note in ADR 0001 (and its SPEC-impact line) keeps one durable home.
  Alternative considered: ADR 0008; rejected as duplication of an existing decision's lifecycle.
- **Archive both BEAM packages inside this change's acceptance flow.**
  Their deltas describe behavior that is already implemented and now becomes default-relevant; archiving them alongside this change's own delta keeps main specs consistent in one sync.

## Risks / Trade-offs

- [Contributors with muscle-memory split-role gRPC workflows break on update] → BREAKING note in docs and PR body; `ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc` restores the old behavior in one variable.
- [BEAM default requires EPMD/cookie setup that gRPC did not] → `docs/local-dev.md` already documents cookie provisioning and `ORCHARD_BEAM_EPMD_PORT`; same-host source dev auto-generates the cookie; two-Mac setup instructions are carried into the AGENTS.md pattern.
- [Hosts with packaged Orchard EPMD on 4369 conflict with the BEAM default] → documented alternate `ORCHARD_BEAM_EPMD_PORT` guidance (the 2026-06-27 and 2026-07-05 smokes both used 43690); startup failure remains visible with the exact remedy in the error.
- [Quiescing regression silently re-enables gRPC default] → regression test asserting no runtime client target is configured in BEAM mode without explicit `ORCHARD_RUNTIME_CLIENT_TARGETS`.
- [Archive sync of three delta sets (two packages plus this change) produces conflicting main specs] → run strict validation after each archive step and review the generated main spec for placeholder prose per AGENTS.md.

## Migration Plan

1. Land the script/config changes with regression tests.
2. Update docs (`AGENTS.md`, `docs/local-dev.md`) and SPEC internal-comms language in the same PR.
3. Amend ADR 0001 with the dated promotion note.
4. After merge, archive `beam-first-runtime-endpoints` and `source-dev-beam-operating-model`, then this change, running strict validation after each sync.
Rollback: revert the PR; the BEAM adapter remains available behind the explicit env var exactly as today.

## Open Questions

- None blocking; packaged-runtime transport promotion is explicitly deferred to a future decision.
