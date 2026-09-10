## Why

Orchard currently exposes one implemented support-bundle path through `orchardctl support bundle create` while also promising an unimplemented Operator API, Console workflow, tray entry point, shared manager, scoped v2 archive, and redaction-manifest contract.
The implemented command owns a private archive pipeline with temporary staging, platform command execution, log traversal, redaction, manifest generation, and best-effort audit production.
Issue #356 found an intermittent Linux race in that private pipeline.

Orchard has not shipped the feature as a beta or GA compatibility commitment.
Removing the implemented path and its dormant promises before beta is simpler and more robust than repairing the race and expanding the archive contract.
The removal must be coherent across `SPEC.md`, active OpenSpec work, code, tests, metrics, lifecycle wording, and live documentation.

## What Changes

- Remove the `orchardctl support bundle create` namespace, implementation, tests, help text, archive pipeline, and output side effects.
- Remove the `support_bundle.generated` audit producer and the `support_bundle` metrics action domain.
- Remove the support-bundle-only `support_scope` vocabulary from the shared cluster-management reason-code contract.
- Remove support-bundle promises from `SPEC.md`, live documentation, and the active `cluster-management-ux-foundation` change.
- Modify the accepted Controller metrics contract from twelve audit domains and 36 audit series to eleven audit domains and 33 audit series.
- Modify lifecycle wording to preserve the retained `support/` namespace and its ownership semantics without describing that namespace as a support-bundle feature.
- Modify API Client secret-handling wording to preserve the prohibition on durable secret storage without naming a removed feature.
- Preserve generic diagnostics, scheduler explanations, operational reason codes, audit history, existing archives, the generic `bundles/` directory, and the retained `support/` lifecycle namespace.
- Perform no automatic cleanup of existing archives and add no compatibility shim or database migration.

## Capabilities

### New Capabilities

- `support-bundle-retirement`: Complete pre-release removal of Orchard's support-bundle product and CLI surfaces while preserving unrelated diagnostics, historical artifacts, and lifecycle ownership boundaries.

### Modified Capabilities

- `controller-prometheus-metrics`: Remove the `support_bundle` audit domain and reduce the bounded audit and total-series arithmetic.
- `app-distribution-lifecycle`: Preserve the retained `support/` namespace through install, update, and default uninstall without treating it as a support-bundle product contract.
- `api-client-provisioning`: Preserve the no-plaintext-token-secret contract after removing the support-bundle noun from its list of durable sinks.

## Impact

- `SPEC.md` impact: remove support-bundle behavior and references from §1.2, §7.3, §7.5, §9.1, §10.2, §10.9, §11.1, §11.8, §11.9, §12.6, §12.7, §13.4, and Milestones 5 and 6 while preserving the retained lifecycle directories in §11.2 and §11.3.
- CLI impact: direct former `support` namespace forms become unknown commands with exit status 1, while generic root-help forms remain successful and omit the removed namespace.
- Governance impact: no new `support_bundle.generated` events are produced, historical text-valued audit rows remain readable, and no migration is required.
- Metrics impact: the audit domain list decreases from twelve to eleven, the audit-events family ceiling decreases from 36 to 33, the accepted Controller metrics floor decreases from 2,600 to 2,597, the runtime worksheet decreases from 2,829 to 2,826, and headroom increases from 2,171 to 2,174.
- Cluster-management impact: bundle-specific parity, scope, artifact, redaction, and task requirements are retired while diagnostics, scheduler explanations, and read-only control-plane status remain.
- Distribution impact: installer, update, uninstall, app-owned lifecycle entries, operator-owned contents, and `support/openssl` behavior remain unchanged.
- Data impact: no schema change, audit-row rewrite, or archive deletion occurs.
