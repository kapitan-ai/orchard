# Contributing to Orchard

Orchard is a sovereign on-prem LLM orchestration platform for Apple Silicon
macOS. This repository is the collaborator-facing source of truth.

## Source Of Truth

1. `SPEC.md` is the top-level normative product/system contract.
2. `README.md` explains what Orchard is and where to start.
3. `CONTRIBUTING.md` explains human collaboration workflow.
4. `AGENTS.md` explains automation and agent workflow.
5. `docs/glossary/CONTEXT.md` defines shared Orchard product language.
6. `docs/process.md` explains artifact lifecycle and review gates.
7. `docs/decisions/**` records durable decisions not already fixed by `SPEC.md`.
8. `openspec/README.md` reserves a structured-change path subordinate to `SPEC.md`.

If these disagree about product behavior, treat the PR as blocked until the
branch reconciles the conflict. `SPEC.md` wins until explicitly updated.

## Getting Started

- Read `README.md` for product overview and status.
- Read `SPEC.md` for normative behavior.
- Use `docs/architecture.md` for repo and runtime orientation.
- Use `docs/local-dev.md` for source development setup.
- Use `docs/tooling.md` for pinned toolchain and validation commands.
- Use `packaging/pkg/README.md` for packaged installer behavior.

## Change Workflow

Small changes can go directly through a normal PR:

- typo and docs clarifications
- internal refactors with no behavior change
- straightforward bug fixes with regression tests
- tactical UI changes that follow `docs/DESIGN.md`

Behavior-changing or architecture-significant work must state its `SPEC.md`
impact in the issue or PR. If the behavior is not covered by `SPEC.md`, update
the relevant durable artifact before or with the implementation.

## Validation

Run the relevant validation workflow from `AGENTS.md` and report exact commands
and outcomes in the PR. For bug fixes, include a regression test when practical.

## Artifact Hygiene

Do not commit prompt exports, local execution evidence, private notes, active
goal packages, raw interview JSON, tool session identifiers, credentials, DSNs,
or machine-specific paths.

Active `goals/<slug>/` packages are local transient execution scaffolding.
Only `goals/README.md` and `goals/_template/**` are tracked.

## PR Checklist

- [ ] I checked whether this changes `SPEC.md` behavior.
- [ ] I updated docs, tests, or decisions that the change affects.
- [ ] I ran relevant validation and recorded outcomes.
- [ ] I did not commit active goal packages or private local artifacts.
- [ ] I did not introduce dependencies on private workbench/session context.
