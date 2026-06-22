# Orchard Docs

This directory contains collaborator-facing orientation, tooling guidance,
process docs, design guidance, and durable decisions for Orchard.

`../SPEC.md` remains the top-level normative product/system/build contract.
Docs here should help contributors navigate and execute work without duplicating
large spec sections.

## Start by intent

### I want to understand Orchard

- [`../SPEC.md`](../SPEC.md) — normative product/system contract.
- [`../README.md`](../README.md) — product overview and current status.
- [`architecture.md`](architecture.md) — repo/runtime map for contributors.
- [`glossary/CONTEXT.md`](glossary/CONTEXT.md) — shared vocabulary and
  glossary.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — human collaborator workflow.
- [`../AGENTS.md`](../AGENTS.md) — automation/agent workflow.

### I want to run it locally

- [`tooling.md`](tooling.md) — mise/uv toolchain and validation commands.
- [`local-dev.md`](local-dev.md) — source-dev setup, `bin/dev`, split-role dev,
  smoke checks, and environment notes.

### I want to contribute code

- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — human collaborator workflow.
- [`../AGENTS.md`](../AGENTS.md) — automation/agent workflow and quality gates.
- [`process.md`](process.md) — artifact lifecycle and review gates.
- [`code-quality.md`](code-quality.md) — Credo, ex_slop, and ex_dna policy.
- [`../openspec/README.md`](../openspec/README.md) — OpenSpec change workflow
  for substantial collaborator-reviewed changes.

### I want to change Console UI

- [`brand-identity.md`](brand-identity.md) — brand palette, typography, logo,
  and visual semantics.
- [`DESIGN.md`](DESIGN.md) — tactical LiveView UI contract downstream of brand
  identity.

### I want to package or install Orchard

- [`../packaging/pkg/README.md`](../packaging/pkg/README.md) — current PKG
  build/operator runbook.
- [`../packaging/container/postgres/README.md`](../packaging/container/postgres/README.md)
  — managed Postgres status; not implemented today.
- [`../packaging/dmg/README.md`](../packaging/dmg/README.md) — reserved future
  DMG media notes.

### I need to make a durable decision

- [`decisions/README.md`](decisions/README.md) — ADR policy.
- [`decisions/_template.md`](decisions/_template.md) — lightweight ADR template.

## Normative vs orientation docs

- Normative product/system behavior: `../SPEC.md`.
- Human workflow: `../CONTRIBUTING.md`.
- Agent workflow and validation: `../AGENTS.md`.
- OpenSpec change intent: `../openspec/README.md` and
  `../openspec/changes/<change-id>/`.
- Artifact lifecycle: `process.md` and `../goals/README.md`.

If docs, tests, implementation, and `SPEC.md` disagree about product behavior,
treat the branch as blocked until reconciled. `SPEC.md` wins until explicitly
updated.

## Writing rules

- Reference relevant `SPEC.md` sections when behavior matters.
- Summarize and link; do not restate large normative sections.
- Prefer practical execution guidance over prose.
- Keep current implementation status separate from target architecture.
- Update or delete stale docs quickly.
- Do not commit raw prompt exports, active goal packages, tool session IDs,
  credentials, DSNs, or machine-specific evidence.
- Promote durable conclusions into standalone docs, decisions, tests, or code.
