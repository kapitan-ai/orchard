## Why

Orchard's cluster management surface is approaching the point where operators need one coherent answer across Console, CLI, Operator API, Admin API, scheduler explanations, diagnostics, and support bundles.
`SPEC.md` already defines node lifecycle, health, scheduler eligibility, Runtime Endpoint observations, operator APIs, admin APIs, diagnostics, support bundles, and HA-lite leadership.
Current implementation reality is not yet aligned with the full contract: `Orchard.Nodes` still performs observational node discovery from successful Runtime Endpoint status reads and inserts new nodes as `active`, while `orchardctl nodes admit` and `orchardctl cluster init` are deferred.
This change defines the operator-facing UX contract before implementation so the next code slices reconcile that gap deliberately instead of growing disconnected Console and CLI behavior.

## What Changes

- Define pending admission as an explicit operator review state for first-observed, provisioned, or registered nodes.
- Define first-observed unregistered Runtime Endpoint observations as observed admission candidates outside the node lifecycle state machine until they are reconciled to a provisioned placeholder or registered node.
- Define rejected pending admission as admission-decision metadata, not a `decommissioning` lifecycle transition.
- Require Console, CLI, Operator API, and Admin API surfaces to keep lifecycle, health, freshness, transport reachability, runtime readiness, compatibility, scheduling, and warnings distinct.
- Define fixed operator-facing reason-code vocabularies for scheduler explanations and node action previews.
- Require CLI and Console parity for node list, node detail, admission review, action eligibility, scheduler explanation, diagnostics, support bundle creation, and HA-lite read-only status.
- Define a safe action model for eligibility-changing and destructive node operations: cordon, uncordon, drain, maintenance, resume, admit, reject pending admission, and decommission.
- Define support bundle and diagnostics expectations, including scope selection, redaction manifest, and shared CLI/Console behavior.
- Keep HA-lite leadership and lock status read-only in this foundation change, with mutating failover or leadership actions deferred to a later accepted change.
- Exclude product code implementation from this change package.

## Capabilities

### New Capabilities

- `cluster-management-ux`: Operator-facing cluster UX contract for node admission, lifecycle state presentation, reason-code taxonomy, CLI/Console parity, safe node actions, scheduler explanations, diagnostics, support bundles, and HA-lite status.

### Modified Capabilities

- None.
  No accepted OpenSpec capability currently owns the cluster-management UX contract.

## Impact

- SPEC.md impact: this change refines `SPEC.md` §1.1, §1.2, §3.3, §4.1 through §4.9, §5.4 through §5.10, §7.3, §7.4, §7.5, §9, §10.2, §11.8, §11.9, §12.7, §13.4, §13.7, and Milestones 3 through 5.
- Current implementation impact: `apps/orchard_controller/lib/orchard/nodes.ex` must stop treating first successful observation as automatically admitted and active when this behavior is implemented.
- Current data-model impact: implementation slices need the `node_admission_candidates` and `node_admission_decisions` persistence contract from `SPEC.md` §8 to store observed candidates and rejected decisions without adding lifecycle enums absent from `SPEC.md`.
- Current audit impact: implementation slices need cluster-scoped audit events for node admission, rejection, rejection clearance, decommission, HA-lite write-path decisions, and cluster-scoped support bundles.
- Current CLI impact: `apps/orchard_cli/lib/orchard_cli/commands/nodes.ex` currently supports `nodes list` and defers `nodes admit`; implementation slices must add the parity commands described here.
- Current Console impact: `apps/orchard_controller/lib/orchard/console/nodes_live.ex` currently shows registered inventory and live runtime diagnostics; implementation slices must add admission review, action previews, reason-code detail, and diagnostics entry points without collapsing signal categories.
- Current diagnostics impact: `apps/orchard_cli/lib/orchard_cli/commands/support.ex` already creates support bundles with redaction and manifests; implementation slices must align Console-triggered support bundles and node diagnostics with the same contract.
- Security impact: support bundle and diagnostic surfaces must preserve `SPEC.md` §10.2 secret handling and must never include plaintext secrets, credentials, DSNs, prompt bodies, response bodies, or raw local evidence logs unless an accepted capture-mode contract explicitly permits them.
- HA-lite impact: this change only defines read-only leadership and advisory-lock visibility; failover, leadership transfer, and standby write-path UX remain future work.
