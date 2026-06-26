## Context

Orchard already models Controller runtime execution through the Runtime Endpoint Interface, and `SPEC.md` §1.2 and §7.5 allow default-off BEAM Distribution for admitted first-party Controller and Node Agent services.
The existing BEAM Runtime Endpoint adapter assumes that BEAM Distribution has already been started with compatible node names, cookies, network reachability, and target addresses.
Before this change, source-dev entrypoints still booted unnamed Mix VMs and configured the legacy gRPC compatibility target list.

This design turns the accepted BEAM-first Runtime Endpoint direction into an apply-ready source-dev operating model.
It is intentionally narrower than production BEAM Distribution hardening.
It covers split-role source-dev first, because `bin/dev-controller` and `bin/dev-node-agent` exercise the real Controller-to-Node Agent boundary.
All-in-one `bin/dev` remains on the current gRPC compatibility default until a separate default-promotion change is accepted.

## Goals / Non-Goals

**Goals:**

- Define the source-dev launch policy for BEAM Runtime Endpoint mode on `bin/dev-controller` and `bin/dev-node-agent`.
- Define long-name BEAM node naming, IPv4-literal target hosts, explicit cookie material, bounded distribution ports, and EPMD policy for source dev.
- Define the BEAM Runtime Endpoint env/config surface separately from the legacy gRPC compatibility target surface.
- Define visible failure behavior when BEAM mode is selected.
- Define the smoke-evidence gate required before source-dev defaults can be promoted.
- Preserve Postgres as durable cluster truth and Runtime Endpoint Observations as the scheduler-visible state seam.

**Non-Goals:**

- Do not update `orchardctl env init` to render the Source-dev BEAM env surface in this implementation slice; defer CLI scaffolding to a separate change.
- Do not flip all-in-one `bin/dev` from gRPC compatibility to BEAM Runtime Endpoint mode.
- Do not remove the gRPC Compatibility Adapter.
- Do not define production or packaged BEAM Distribution secret injection, TLS distribution, epmdless distribution, launchd policy, or release-cookie handling.
- Do not introduce external Runtime Endpoint adapters.
- Do not change public inference API semantics, scheduler ranking policy, request-state semantics, Postgres schema, or the Node Agent to Worker Runtime boundary.

## Decisions

### Split-role source dev is the first BEAM operating target

BEAM Runtime Endpoint mode is implemented first for `bin/dev-controller` and `bin/dev-node-agent`.
Both processes must start as named distributed BEAM nodes when BEAM transport is selected.
This keeps the validation path close to the real distributed source-dev topology and avoids hiding operational defects inside an all-in-one VM.

Alternative considered: change all-in-one `bin/dev` first.
That is simpler to run, but it would not prove remote BEAM Distribution, cookie sharing, EPMD reachability, or remote Runtime Endpoint RPC behavior.

### Source-dev BEAM uses long node names with IPv4-literal hosts

Source-dev BEAM node names should use long-name format, such as `orchard_controller@100.x.y.z` and `orchard_node_agent@100.x.y.z`.
Guarded BEAM Runtime Endpoint targets should require the host part to be an IPv4 literal.
This keeps CIDR guardrail validation deterministic and avoids source-dev ambiguity around hostname resolution, local DNS, Bonjour, split-horizon names, and different network interfaces.

Alternative considered: accept short names or arbitrary hostnames.
Short names cannot communicate with long-name nodes and do not fit two-Mac source dev reliably.
Hostnames can be supported later, but they require explicit resolution and guardrail policy before they can be trusted.

### Cookie material is explicit and source-dev scoped

Source-dev BEAM mode should use `ORCHARD_BEAM_COOKIE_FILE` rather than ambient `$HOME/.erlang.cookie`.
Same-host source dev may generate a repo-local `tmp/dev/beam.cookie` file when absent.
Two-Mac source dev must provision identical cookie material on both Macs before launch.
The file must be readable only by the owner, with mode `0600` or stricter, and its contents must never be printed.

Alternative considered: rely on the VM default cookie file.
That is fragile across launchd, different users, worktrees, shell sessions, and remote hosts.
It also makes failures harder to diagnose because the configured Runtime Endpoint mode would depend on undeclared machine state.

### Distribution networking is bounded and visible

Source-dev BEAM mode sets an explicit EPMD port policy, defaulting to TCP `4369`, and a configured distribution listener port range through `ORCHARD_BEAM_DIST_PORT_MIN` and `ORCHARD_BEAM_DIST_PORT_MAX`.
The implementation defaults the controller distribution range to TCP `52171..52171` and the node-agent range to TCP `52172..52172`.
Startup output may show node name, cookie file path, EPMD port, and distribution port range.
Startup output must not show cookie contents.
The two-Mac smoke runbook must state that both EPMD and the bounded distribution listener range must be reachable over the trusted source-dev network.

Alternative considered: leave distribution listener ports unbounded.
That follows BEAM defaults, but it is hard to firewall, troubleshoot, or repeat across two Macs.

### BEAM Runtime Endpoint env vars are separate from gRPC compatibility vars

`ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam` should select the BEAM Runtime Endpoint adapter for source-dev Runtime Endpoint operations.
`ORCHARD_RUNTIME_ENDPOINT_TARGETS` should provide BEAM target node names such as `orchard_node_agent@100.x.y.z`.
`ORCHARD_RUNTIME_CLIENT_TARGETS` remains the gRPC compatibility target list and should not be overloaded for BEAM node names.
`ORCHARD_BEAM_NODE_NAME`, `ORCHARD_BEAM_COOKIE_FILE`, `ORCHARD_BEAM_DIST_PORT_MIN`, `ORCHARD_BEAM_DIST_PORT_MAX`, and `ORCHARD_BEAM_EPMD_PORT` define the local distributed-node bootstrap surface.

Alternative considered: infer BEAM targets from `ORCHARD_RUNTIME_CLIENT_TARGETS`.
That would mix `host:port` gRPC addresses with `service@host` BEAM node addresses and make compatibility mode ambiguous.

### BEAM mode fails visibly rather than falling back automatically

When BEAM mode is selected, missing node names, invalid target node names, absent or weak cookie files, port configuration errors, distribution connection failures, and Runtime Endpoint RPC failures must fail visibly in the BEAM path.
The same request must not silently retry through gRPC.
gRPC remains available when explicitly selected through the compatibility transport configuration.

Alternative considered: automatic gRPC fallback on BEAM failure.
That would make early source-dev demos smoother, but it would hide the exact class of operating-model defects this change is meant to surface.

### Smoke evidence gates default promotion

Before any source-dev default is promoted to BEAM Runtime Endpoint mode, the team must record durable two-Mac smoke evidence in a sanitized repo document such as `docs/investigations/source-dev-beam-smoke-<date>.md`.
Required evidence includes date, commit, sanitized hosts, commands, controller and node-agent BEAM node names, remote Runtime Endpoint RPC evidence, Console Nodes reachability for local and remote Node Agents, `GET /v1/models` returning `200`, and `POST /v1/chat/completions` completing through Console Playground or an equivalent API request.
Committed evidence must not include cookie material, credentials, raw local evidence logs, local tool session identifiers, or machine-specific filesystem paths.

Alternative considered: promote after unit or same-host tests only.
Those tests are useful, but they do not prove the source-dev operating model across real host, cookie, and distribution-network boundaries.

## Risks / Trade-offs

Risk: Source-dev BEAM mode can fail for local networking reasons unrelated to Runtime Endpoint code.
Mitigation: keep EPMD and distribution ports explicit, print non-secret startup diagnostics, and document the smoke reachability checklist.

Risk: Requiring IPv4-literal hosts is less ergonomic than hostnames or IPv6 literals.
Mitigation: treat hostname target support as a later enhancement after resolution and CIDR guardrail behavior are specified.

Risk: Same-host generated cookie files can be confused with production secret handling.
Mitigation: scope repo-local cookie generation to source dev only and explicitly exclude packaged or release runtime secret handling from this change.

Risk: Operators or contributors may assume gRPC fallback still happens after selecting BEAM mode.
Mitigation: make no-fallback behavior normative, test it, and keep compatibility mode explicitly selectable.

Risk: Smoke evidence could become stale after later transport changes.
Mitigation: record the commit with the smoke evidence and require new evidence before future default-promotion changes.

## Migration Plan

1. Implement source-dev env/config parsing for the BEAM Runtime Endpoint surface without changing default source-dev transport.
2. Add shared source-dev launch bootstrap used by `bin/dev-controller` and `bin/dev-node-agent` when BEAM mode is selected.
3. Implement explicit cookie-file generation or validation, strict permissions, and secret-safe diagnostics.
4. Add BEAM node-name, EPMD, and distribution-port launch flags for split-role source-dev processes.
5. Wire BEAM Runtime Endpoint target selection from `ORCHARD_RUNTIME_ENDPOINT_TARGETS` while leaving `ORCHARD_RUNTIME_CLIENT_TARGETS` scoped to gRPC compatibility.
6. Add unit and integration coverage for parsing, cookie validation, node-name validation, IPv4-literal target rules, no automatic fallback, and split-role launch behavior.
7. Run the two-Mac smoke and record durable evidence before proposing any default promotion.
8. Propose any change to all-in-one `bin/dev` or default source-dev transport separately after the evidence gate passes.

Rollback is configuration-based during implementation.
Contributors can return to the existing source-dev gRPC compatibility path by selecting or leaving the compatibility transport in place.
No data migration is expected because this operating model does not change Postgres schema or durable request data.

## Resolved Implementation Notes

- Source-dev BEAM uses TCP `52171` for the controller distribution listener and TCP `52172` for node-agent distribution listeners by default.
- Cross-Mac cookie provisioning remains a documented manual setup step; this slice does not add a copy or secret-manager helper.
- Automated coverage uses config tests and a shell bootstrap harness for launch behavior.
  Real two-Mac distributed Runtime Endpoint evidence remains the smoke gate tracked in tasks 5.4 and 5.5.
