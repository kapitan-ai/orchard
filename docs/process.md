# Orchard Process

Use the lightest process that protects Orchard's product contract.

## Required Collaboration Surface

Contributors need GitHub and this repository. Local tools may help, but they do
not own product truth. Historical coordination workspaces can inform work, but
active guidance must be promoted into this repo before it becomes Orchard
truth.

For repo/runtime orientation, start with [`architecture.md`](architecture.md).
For transient goal-package policy, see [`../goals/README.md`](../goals/README.md).
For durable decisions, see [`decisions/README.md`](decisions/README.md).

## Workflow Selection

| Work | Process |
|---|---|
| Typo or docs clarification | Direct PR |
| Small bug | Direct PR plus regression test when practical |
| Internal refactor | Direct PR plus validation |
| Behavior change | OpenSpec change or PR must state `SPEC.md` impact |
| Architecture decision | Add or update `docs/decisions/**` when not already covered |
| Normative invariant change | Update `SPEC.md` in the same branch |
| Collaborator-owned substantial change | OpenSpec change package plus normal PR |
| New or restored distribution channel | Fresh OpenSpec proposal plus a separate implementing PR |

## Artifact Lifecycle

| Stage | Location | Commit policy |
|---|---|---|
| Idea or issue | GitHub issue, PR note, local scratch | Commit only if standalone and useful |
| Local goal package | `goals/<slug>/` | Ignored; not committed by default |
| Local context/evidence | `.codex/`, `.claude/`, local evidence dirs, and logs | Ignored unless sanitized and promoted |
| Investigation or smoke evidence | PR/issue comments and decision records | Never committed as standalone docs; promote durable conclusions |
| OpenSpec proposed change | `openspec/changes/<change-id>/` | Commit when ready for collaborator review |
| Shared product language | `docs/glossary/CONTEXT.md` | Commit when standalone and aligned with `SPEC.md` |
| Durable decision | `docs/decisions/**` | Commit when standalone and product-relevant |
| Accepted OpenSpec behavior | `openspec/specs/**`, `SPEC.md`, docs, tests, code | Commit only after reconciliation |
| Normative behavior | `SPEC.md`, code, tests | Commit through normal review |

## Distribution Channel Re-Approval

Dormant scripts, assets, tests, docs, archived changes, or superseded decisions
do not authorize a distribution channel.
Native PKG is not a current supported Orchard channel.
Restoring it or introducing another channel requires a fresh OpenSpec proposal
and a separate implementing pull request that reconcile `SPEC.md`, decisions,
security posture, operator docs, artifact governance, and validation gates.
The initial source-availability transition does not promise a supported public binary.
Public binary support requires an explicit release decision and completion of every applicable build, verification, signing, notarization, stapling, and publication gate.

## Re-Grounding Rule

Plans are snapshots. Before executing or promoting an old plan, compare it with
current `main`, current `SPEC.md`, and the affected files. If the plan is stale,
rewrite the durable conclusion instead of copying the stale plan.

## Review Gates

- `SPEC.md` impact is explicit.
- Product docs do not duplicate large normative sections from `SPEC.md`.
- Private local artifacts are not committed.
- Active `goals/<slug>/` directories are not staged.
- Non-outdated review threads that touch security, runtime startup, contract behavior, cross-platform shell behavior, or data safety are resolved or explicitly disproven against the current PR head.
- External validation summaries are tied to the exact commit that is being merged.
  For shell, packaging, native helper, and portability-sensitive changes, record the OS, shell, and critical tool variants that were exercised.
- Security-sensitive shell preflights fail closed on empty, nonnumeric, multiline, or otherwise unexpected command output.
  Tests should cover platform-specific command behavior and launcher-shaped conditional paths such as `if`, `!`, and `... || return $?` when `set -e` semantics matter.
- OpenSpec-backed changes pass
  `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate <change-id> --type change --strict --no-interactive`.
- Archived or synced OpenSpec behavior passes
  `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive`.
- Archived OpenSpec specs do not contain placeholders such as `Purpose TBD`.
- Validation commands and outcomes are recorded.

## Optional Local Tools

Local agent tools, review tools, skills, notebooks, and execution harnesses may
accelerate work. Their raw outputs are not product truth. Commit only standalone
docs, tests, code, or decisions that are understandable from this repository.
For substantial agentic changes, RepoPrompt review or planning second opinions
are encouraged when available; record only the resulting standalone conclusions.
