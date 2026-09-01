## Why

The packaged local node-command route currently loads `orchard_cli` into the Controller release only to evaluate `OrchardCLI.ControllerRPC`.
That reverse release dependency contradicts the accepted Controller-owned authority direction even though the invoked domain operations already belong to `orchard_controller`.

Issue #324 is the accepted next portability slice after Darwin helper eviction and required Linux validation fan-out.
It removes the release-composition dependency without selecting a normal authenticated CLI migration family.

## What Changes

- Move the private packaged node-command RPC bridge, compatibility parser and presenter, and narrow supervised-Repo runner under Controller ownership.
- Keep the existing Controller domain operations as the sole preview, authorization, mutation, audit, and revalidation implementation.
- Update the packaged `orchardctl` wrapper to invoke the Controller-owned entrypoint.
- Remove `orchard_cli` from the `orchard_controller` release application list.
- Preserve `ORCHARDCTL_RPC_V1`, the closed command allowlist, Base64 argument safety, one-envelope framing, output routing, statuses, and interruption behavior.
- Preserve standalone CLI behavior through a thin adapter that continues to use the existing standalone Repo runtime.
- Prove that the wrapper and Controller release activate and roll back as one app-owned payload transaction and that version skew fails closed.

No `SPEC.md` or decision-record change is required.
This change implements `SPEC.md` §§2.5 and 11.9, Milestone 8, ADR 0024, and issue #324.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `operator-command-authority`: Makes the current packaged compatibility handler Controller-owned without authorizing another command or normal remote migration.
- `app-distribution-lifecycle`: Treats the packaged wrapper and Controller release as one transactional activation and rollback unit whose temporary skew fails closed.
- `portability-validation`: Requires assembled-release independence and dependency-selected validation evidence for this release-composition change.

## Impact

- The Controller release no longer contains or loads CLI implementation.
- The standalone CLI release and unrelated direct-Repo command families remain unchanged.
- The private evaluated module name changes only inside the app-owned payload contract.
- No database schema, public API, remotely reachable authority, Worker Runtime, provider, Linux packaging, or support claim changes.
