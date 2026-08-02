# M0 — Foundation and Packaging Skeleton

## Status

- Phase: complete
- Owner: najib
- Spec refs: `SPEC.md` §2.4, §3.1, §3.2, §8, §11, §14 (M0)
- Completed: 2026-03-09
- Final commit: 970ec51

## Planning note

This file is a non-normative execution plan for Milestone 0. `SPEC.md` remains authoritative; where this plan differs in detail or timing, the spec wins. The checkpoints below are planning aids, while **Milestone exit criteria** maps directly to `SPEC.md` §14.

## Goal

Establish the Orchard repository skeleton, release boundaries, health endpoints, database scaffold, and macOS packaging skeleton without implementing inference, scheduling, or governance behavior yet.

## In scope

- umbrella project root
- Elixir app boundaries
- controller release boot
- node-agent release boot
- CLI release boot
- Ecto repo + initial migrations scaffold
- health endpoints
- proto directory scaffold
- native helper directory scaffold
- launchd plist skeleton
- DMG/PKG packaging skeleton
- managed Postgres packaging/container skeleton and operator-safe guard

## Out of scope

- inference execution
- tokenizer implementation
- MLX worker implementation
- node registration flow
- heartbeats
- scheduler logic
- auth/RBAC
- quotas
- request FSM behavior
- public OpenAI-compatible endpoints beyond health if not needed for bootstrapping

## Planned execution checkpoints

### Repo structure

- umbrella root created
- `apps/orchard_shared`
- `apps/orchard_controller`
- `apps/orchard_node_agent`
- `apps/orchard_cli`
- `native/orchard_worker_mlx`
- `native/orchard_tokenizer`
- `proto/cluster/v1`
- `packaging/dmg`
- `packaging/pkg`
- `packaging/launchd`
- `packaging/container`

### Bootable releases

- controller boots
- node agent boots
- CLI entrypoint exists

### Database scaffold

- Ecto repo configured
- migration pipeline wired
- placeholder initial migration strategy agreed

### Health surface

- `/health/live` implemented as a basic controller liveness endpoint
- `/health/ready` evaluates the staged M0 predicate identified as
  `orchard.readiness.legacy_m0.v1`:
  - Postgres reachable
  - migrations current, once the repo/migration pipeline is wired
  - public API HTTPS enabled
  - controller boot completed
- Public `/health/live` and `/health/ready` expose exact status-only bodies.
  Detailed M0 checks and observations are available only through authenticated
  Operator `/ops/v1/health`.
- tenant/model/key cache loading and Active/Standby write-path leadership remain
  deferred to the later complete `SPEC.md` §3.1 aggregate. The staged predicate
  does not claim full §3.1 readiness.

### Packaging scaffold

- launchd plist skeletons exist
- DMG/PKG packaging skeleton exists
- managed Postgres container skeleton and guard exist

## Proposed implementation order

1. establish umbrella root and shared config
2. create umbrella apps and release names
3. wire controller supervision shell
4. wire node-agent supervision shell
5. wire CLI shell
6. add Ecto repo and migrations scaffold
7. add health endpoints
8. create proto/native directory scaffolds
9. create launchd plist skeletons
10. create DMG/PKG/container packaging skeleton

## Initial scaffolding assumptions

These are early implementation assumptions to preserve spec-aligned separation during M0, not final architecture commitments.

### `orchard_shared`

Likely initial home for:

- shared types
- shared config parsing
- shared RPC/proto wrappers
- common error helpers

### `orchard_controller`

Likely initial home for:

- API endpoint shell
- repo
- controller supervision tree shell
- health endpoints

### `orchard_node_agent`

Likely initial home for:

- node-agent supervision shell
- placeholder runtime/model/worker namespaces

### `orchard_cli`

Likely initial home for:

- `orchardctl` entrypoint shell
- deferred command-group routing

## Milestone exit criteria

Per `SPEC.md` §14, Milestone 0 exits when:

- controller starts on macOS
- node agent starts on macOS
- `Orchard.app` assembles as a valid app bundle and passes sandboxed service-lifecycle rollback and retention tests
- the verified app assembles into a mountable DMG without nested signature or entitlement drift
- PKG installs launchd services correctly

PR #85 later extended the current `SPEC.md` acceptance contract after the milestone's recorded 2026-03-09 completion.
The `Orchard.app` rollback and retention criterion and the mounted-DMG signature and entitlement criterion above are post-completion additions satisfied by the merged app-lifecycle work rather than gates used for the original completion record.

## Supporting verification signals

These checks support implementation confidence during M0 but are not independent milestone exit criteria:

- `mix compile` succeeds
- CLI binary/module entrypoint resolves
- `/health/live` responds
- `/health/ready` responds with exact status-only JSON and authenticated
  `/ops/v1/health` reports the identified staged predicate described above
- packaging skeleton matches expected Orchard naming and layout

## Validation

Validation and reporting follow `AGENTS.md`.

For M0 work, run the applicable workflow from the repository root and report what passed, failed, or is not yet wired. If a tool such as Dialyzer or coverage is not configured yet, call that out explicitly and track the setup work instead of silently skipping it.

During M0, shallow scaffold apps may carry temporary low or zero coverage thresholds where their runtime behavior is still placeholder-only. Treat those thresholds as milestone-scoped exceptions, not steady-state quality targets.

## Open questions

- Phoenix vs lighter Plug-only endpoint shell for M0
- gRPC library/codegen choice
- proto generation workflow
- release layout under `rel/`
- whether to scaffold `macos/OrchardTray` in M0 or defer until packaging/UI work starts

## Notes

- Keep M0 intentionally shallow.
- Avoid implementing M1 behavior early.
- Prefer scaffolding that preserves spec-aligned boundaries.
