## Context

The implemented support-bundle feature is a synchronous local CLI archive pipeline.
It gathers system and service evidence, traverses logs, stages files, emits a manifest, creates a compressed archive, and records a best-effort audit event when the Controller Repo is available.
The broader v2 contract exists only in product and planning artifacts.
There is no implemented Operator API route, Console workflow, tray workflow, shared manager, scoped v2 artifact, or redaction-manifest consumer that creates a compatibility obligation.

Issue #356 identified an intermittent Linux failure where a GNU `find` process could exit between `Port.info/1` and `Port.close/1`.
Repairing that race would retain a private pipeline that Orchard no longer intends to ship.

The `support/` directory under the Orchard Application Support root is also used for app-owned lifecycle entries such as install-role and transactional state.
Its name does not make the directory itself a support-bundle feature.
The removal therefore distinguishes product behavior from directory ownership.

## Goals

- Remove the entire pre-release support-bundle product surface in one coherent pull request.
- Preserve unrelated diagnostics, scheduler explanations, operational reason codes, and control-plane status.
- Preserve installer ownership and retention semantics for `support/`, `bundles/`, and existing operator-owned contents.
- Preserve historical audit rows without migration.
- Keep every implementation commit internally consistent across code and live contract documentation.

## Non-Goals

- Do not repair or retain the issue #356 traversal race.
- Do not add a compatibility shim, deprecated command, archive reader, migration, or replacement bundle format.
- Do not delete existing archives or operator-owned files.
- Do not rename unrelated diagnostic fixtures, imported model bundles, or packaging paths merely because they contain the word `support` or `bundle`.
- Do not change general diagnostic collection, scheduler explanation behavior, lifecycle transaction semantics, or `support/openssl` custody.
- Do not rewrite archived OpenSpec history beyond normal accepted-change synchronization metadata.

## Decisions

### Remove the feature as one contract boundary

The CLI implementation and the dormant v2 promises are one product decision.
Keeping any one of the Operator API, Console, tray, manager, scope, or redaction-manifest promises would leave a future obligation without an implementation path.
The change removes all of them together.

### Keep one pull request and three logical commits

The delivery uses three coherent commits:

1. Proposed OpenSpec package only.
2. Atomic live removal across implementation, tests, `SPEC.md`, active OpenSpec work, metrics, and live documentation.
3. Accepted-spec synchronization, archive, and partial-supersession annotations after explicit owner acceptance.

Separating live code removal from live documentation would create an intermediate commit that still advertises a missing operator command.
The live removal is therefore one atomic commit even though it spans multiple subsystems.

### Preserve directory ownership, not bundle semantics

Install and update continue preserving operator-owned contents under `config/`, `data/`, `models/`, `bundles/`, `logs/`, and the retained `support/` namespace.
Default uninstall continues removing app-owned payloads and support entries while retaining non-app-owned contents.
No lifecycle manifest, Swift policy, transaction, or ownership rule changes.

### Preserve audit history without migration

Audit actions are stored as ordinary text.
Historical `support_bundle.generated` rows do not require an enum value or live action-domain mapper to remain readable.
The removal stops new production and removes bounded metrics normalization, while generic audit persistence and readers remain unchanged.
If a historical or otherwise unknown support-bundle action is submitted through the generic audit writer, the authoritative text row remains committed while metrics enter the existing bounded rejected-tuple degradation state.

### Remove support-only reason vocabulary

The `support_scope` vocabulary exists solely to enumerate dormant v2 bundle scopes.
No independent operational consumer uses it.
The removal deletes that vocabulary and its contract tests while preserving scheduler, blocker, warning, consequence, confirmation, dispatch-capacity, and other operational codes.

### Use the existing unknown-command boundary

After the support dispatcher is removed, direct forms such as `support`, `support --help`, and `support bundle create --output <path>` fall through the existing unknown-command path with exit status 1.
Generic forms beginning with `help`, `--help`, or `-h` continue rendering root help because that is the existing CLI-wide contract.
No special tombstone dispatcher is added.

## Metrics Arithmetic

The existing audit-events family uses one series for every bounded audit action domain and outcome pair.
Removing one domain removes three series because the outcomes remain `succeeded`, `failed`, and `denied`.

| Quantity | Before | After |
|----------|--------|-------|
| Audit domains | 12 | 11 |
| Audit series | 36 | 33 |
| Accepted Controller metrics floor | 2,600 | 2,597 |
| Attempt and retry delta | 229 | 229 |
| Runtime worksheet | 2,829 | 2,826 |
| Headroom below 5,000 | 2,171 | 2,174 |

## Active OpenSpec Reconciliation

`cluster-management-ux-foundation` is an active proposed change, not an accepted main capability.
The live-removal commit will:

- remove the bundle-specific parity and artifact requirements from its proposal, design, and spec delta;
- keep diagnostics, scheduler explanations, and control-plane status;
- remove bundle references from reason-code consumers;
- change task 5.5 to a diagnostics-only entry point and leave it incomplete until independently delivered;
- mark tasks 6.1 through 6.9 as explicitly retired by `retire-support-bundles` rather than silently deleting them;
- remove support bundles from task 3.3 without marking the remaining consumer work complete unless separately verified; and
- rerun strict validation for the modified active change.

## Validation Strategy

- Validate this proposed package strictly before production edits.
- At the CLI public seam, observe the old positive integration test fail after its expectation is changed but before the dispatcher and implementation are removed.
- Prove direct former namespace forms reject, root help remains valid, and an output path is not created.
- Prove shared reason-code tests no longer expect `support_scope`.
- Prove governance and metrics tests reject the removed action domain and match the revised literal arithmetic.
- Run focused CLI, shared, governance, and metrics tests before the full Orchard Elixir quality workflow.
- Search for semantic v2 residue including `support_scope`, `redaction_manifest`, `included_sections`, `omitted_sections`, and `max_log_bytes`.
- Run the portable Linux suite as negative proof that the former command is unavailable, not as a reproduction of the retired race.
- Run an independent RepoPrompt review against the final diff.

## Rollback

Rollback is the ordinary Git revert of this pre-release removal.
There is no schema or destructive data migration to reverse.
Existing archives and retained lifecycle contents remain untouched throughout the change.
