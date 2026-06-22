# OpenSpec

This directory contains Orchard's initialized OpenSpec workflow.

`SPEC.md` remains Orchard's top-level normative product/system contract.
OpenSpec materials must be subordinate to `SPEC.md` and must not become a
competing source of truth.

## Status

- `config.yaml` selects the `spec-driven` schema.
- Proposed changes live under `changes/<change-id>/`.
- Accepted or archived specs live under `specs/<capability>/spec.md`.
- Archived changes live under `changes/archive/`.

## When To Use OpenSpec

Use OpenSpec for substantial behavior, architecture, API, security/governance,
node lifecycle, scheduling, packaging, or collaborator-owned changes.

Small typo fixes, internal refactors, straightforward bug fixes, and tactical UI
changes may still use direct PRs when `SPEC.md` impact is clear.

## Change Package Shape

A reviewable change package should include:

- `proposal.md` for what changes and why
- `specs/<capability>/spec.md` for requirement deltas
- `tasks.md` for implementation checklist
- `design.md` when the change has technical ambiguity, migration risk,
  security/performance concerns, or cross-module impact

Do not mirror large sections of `SPEC.md` here. Cite or summarize the affected
contract and reconcile accepted behavior back into `SPEC.md`, docs, tests, and
code as needed.

## Validation

Before implementing or handing off an OpenSpec-backed PR:

```sh
mise exec -- npm run openspec -- validate <change-id> --type change --strict --no-interactive
```

After archiving or syncing accepted behavior:

```sh
mise exec -- npm run openspec -- validate --all --strict --no-interactive
```

Strict validation checks structure, not product correctness. Review generated
main specs for placeholders such as `Purpose TBD`, and treat stale or ambiguous
requirements as blockers until reconciled with `SPEC.md`.

## Artifact Hygiene

Commit OpenSpec config and reviewed change/spec artifacts when they are durable
and collaborator-facing.

Do not commit generated `.codex/`, `.claude/`, prompt exports, local context
stores, tool session identifiers, local evidence logs, credentials, DSNs, or
machine-specific paths.
