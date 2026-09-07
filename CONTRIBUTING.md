# Contributing to Orchard

Orchard is a sovereign on-prem LLM orchestration platform with a portable Orchard control-plane core and a currently supported Apple Silicon macOS platform profile.
The accepted next platform target is a Linux Controller profile with external Postgres operating admitted Apple Silicon macOS Nodes under the macOS MLX Node runtime profile.
That target is not supported until the mixed-platform acceptance profile and the remaining Milestone 8 gates in `SPEC.md` pass.
This repository is the collaborator-facing source of truth.

## Source Of Truth

1. `SPEC.md` is the top-level normative product/system contract.
2. `README.md` explains what Orchard is and where to start.
3. `CONTRIBUTING.md` explains human collaboration workflow.
4. `AGENTS.md` explains automation and agent workflow; `CLAUDE.md` imports it for Claude Code.
5. `docs/glossary/CONTEXT.md` defines shared Orchard product language.
6. `docs/process.md` explains artifact lifecycle and review gates.
7. `docs/decisions/**` records durable decisions not already fixed by `SPEC.md`.
8. `openspec/README.md` explains the initialized OpenSpec change workflow
   subordinate to `SPEC.md`.

If these disagree about product behavior, treat the PR as blocked until the
branch reconciles the conflict. `SPEC.md` wins until explicitly updated.

## Participation

Issues and feedback are welcome.
Implementation participation requires prior maintainer agreement.
Najib retains final authority over project direction, contribution acceptance, merges, releases, and publication.
AI-assisted work must have an accountable human contributor who reviews and stands behind the result.
Keep discussions and contributions respectful.

## Contribution Terms

By submitting a pull request, you agree that your Orchard-authored contributions are licensed under [Apache-2.0](LICENSE) and confirm that you have the right to submit them under those terms.
Identify any included third-party material and preserve its applicable licenses and notices.
DCO sign-off trailers and a separate contributor license agreement are not required.

## Getting Started

- Read `README.md` for product overview and status.
- Read `SPEC.md` for normative behavior.
- Use `docs/architecture.md` for repo and runtime orientation.
- Use `docs/local-dev.md` for source development setup.
- Use `docs/tooling.md` for pinned toolchain and validation commands.
- Use `packaging/README.md` for payload, app lifecycle, and operator behavior.

## Change Workflow

The direct-PR path does not waive the participation requirements above.
Small changes can go directly through a normal PR:

- typo and docs clarifications
- internal refactors with no behavior change
- straightforward bug fixes with regression tests
- tactical UI changes that follow `docs/DESIGN.md`

Behavior-changing or architecture-significant work must state its `SPEC.md`
impact in the issue or PR. If the behavior is not covered by `SPEC.md`, update
the relevant durable artifact before or with the implementation.

Use OpenSpec for substantial behavior, architecture, API, security/governance,
node lifecycle, scheduling, packaging, or collaborator-owned changes. OpenSpec
change packages live under `openspec/changes/<change-id>/` and must remain
subordinate to `SPEC.md`.

## Validation

Run the relevant validation workflow from `AGENTS.md` and report exact commands
and outcomes in the PR. For bug fixes, include a regression test when practical.

For OpenSpec-backed work, also run:

```sh
OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate <change-id> --type change --strict --no-interactive
```

After archiving or syncing accepted OpenSpec behavior, run:

```sh
OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive
```

Review archived specs for placeholders such as `Purpose TBD`; strict validation
does not catch unfinished prose.

## Artifact Hygiene

Do not commit prompt exports, local execution evidence, private notes, active
goal packages, raw interview JSON, local context stores such as `.codex/` or
`.claude/`, tool session identifiers, credentials, DSNs, or machine-specific
paths.

Active `goals/<slug>/` packages are local transient execution scaffolding.
Only `goals/README.md` and `goals/_template/**` are tracked.

## PR Checklist

- [ ] I checked whether this changes `SPEC.md` behavior.
- [ ] I updated docs, tests, or decisions that the change affects.
- [ ] I ran relevant validation and recorded outcomes.
- [ ] I did not commit active goal packages or private local artifacts.
- [ ] I did not introduce dependencies on private workbench/session context.
