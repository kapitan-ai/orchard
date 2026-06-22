# Orchard Process

Use the lightest process that protects Orchard's product contract.

## Required Collaboration Surface

Contributors need GitHub and this repository. Local tools may help, but they do
not own product truth. Historical coordination workspaces can inform work, but
active guidance must be promoted into this repo before it becomes Orchard
truth.

## Workflow Selection

| Work | Process |
|---|---|
| Typo or docs clarification | Direct PR |
| Small bug | Direct PR plus regression test when practical |
| Internal refactor | Direct PR plus validation |
| Behavior change | PR must state `SPEC.md` impact |
| Architecture decision | Add or update `docs/decisions/**` when not already covered |
| Normative invariant change | Update `SPEC.md` in the same branch |

## Artifact Lifecycle

| Stage | Location | Commit policy |
|---|---|---|
| Idea or issue | GitHub issue, PR note, local scratch | Commit only if standalone and useful |
| Local goal package | `goals/<slug>/` | Ignored; not committed by default |
| Execution evidence | local evidence dirs and logs | Ignored unless sanitized and promoted |
| Shared product language | `docs/glossary/CONTEXT.md` | Commit when standalone and aligned with `SPEC.md` |
| Durable decision | `docs/decisions/**` | Commit when standalone and product-relevant |
| Normative behavior | `SPEC.md`, code, tests | Commit through normal review |

## Re-Grounding Rule

Plans are snapshots. Before executing or promoting an old plan, compare it with
current `main`, current `SPEC.md`, and the affected files. If the plan is stale,
rewrite the durable conclusion instead of copying the stale plan.

## Review Gates

- `SPEC.md` impact is explicit.
- Product docs do not duplicate large normative sections from `SPEC.md`.
- Private local artifacts are not committed.
- Active `goals/<slug>/` directories are not staged.
- Validation commands and outcomes are recorded.

## Optional Local Tools

Local agent tools, review tools, skills, notebooks, and execution harnesses may
accelerate work. Their raw outputs are not product truth. Commit only standalone
docs, tests, code, or decisions that are understandable from this repository.
For substantial agentic changes, RepoPrompt review or planning second opinions
are encouraged when available; record only the resulting standalone conclusions.
