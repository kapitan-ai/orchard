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

## Tracking and Publication

Linear is Orchard's private product-management system of record for outcomes,
priorities, ownership, product decisions, acceptance tracking, and current status.
GitHub is the public intake, collaboration, source-review, and release surface,
and remains authoritative for source, commits, PR review, CI, and merge/release
state. `SPEC.md` and accepted repository contracts remain normative for product
behavior; private decisions must be reconciled there before implementation.
Contributors do not need Linear access. Execution threads retain detailed evidence;
the historical coordination ledger is not a second live backlog.

### Private capture and public intake

Keep private ideas and prioritization in Linear. For an actionable GitHub report,
first check for an existing Linear outcome, then link or minimally import the
report with its public URL, attribution, and relevant evidence. Keep public
discussion understandable on GitHub without exposing private commentary,
identifiers, or links. Security reports follow [`SECURITY.md`](../SECURITY.md),
not public intake. Import is not an implementation commitment or permission to
close the public report. GitHub closure or merge does not by itself complete a
broader Linear outcome; reconcile its acceptance separately.

If Linear or the required access is unavailable, report the blocked private
capture/import. Do not create a public issue, gist, comment, or attachment as a
fallback. Existing authorization for unrelated public work is unaffected.
This policy does not authorize bulk migration, automatic synchronization, or
changes to existing issues, states, labels, or ownership.

### Public-ready decision

Nothing moves from private planning to GitHub without an explicit public-ready
decision by the accountable product owner. Record the approver, date, approved
content/revision or bounded scope, destination/audience, exclusions, and eventual
published result on the private issue. Review titles, labels, attachments,
screenshots, commit messages, and links as well as body text. Publish only the
approved sanitized scope as a standalone account, never a raw private export.

One explicit authorization may cover a bounded delivery and its routine updates;
it need not be repeated for each command. New private disclosures or materially
expanded scope require a new decision. Assignment, tracker labels/states,
implementation permission, green CI, or automated review do not grant publication
authority. Public-ready approval does not grant merge, release, or deployment
authority; existing participation, human review, and approval gates still apply.

Trivial public fixes may use the existing direct-PR path without a mandatory
Linear issue. This exception does not permit private disclosure or waive
participation, publication, validation, or merge controls. Retired tracker/agent
workflow instructions cannot override these rules or trigger public writes.

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
| Private idea or prioritization | Linear | No raw private material in the repository |
| Public report or trivial public fix | GitHub issue or PR | Minimal private triage where needed; no mandatory Linear issue for a trivial public fix |
| Public-ready promotion | Approved sanitized GitHub/repository scope | Explicit accountable product-owner decision; preserve separate merge/release/deploy gates |
| Local goal package | `goals/<slug>/` | Ignored; not committed by default |
| Local context/evidence | `.codex/`, `.claude/`, local evidence dirs, and logs | Ignored unless sanitized and promoted |
| Investigation or smoke evidence | Private execution records; approved summaries in PR/issue comments and decision records | Never commit raw private evidence or standalone smoke logs; promote durable conclusions |
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
The initial source-availability transition is source-only under the repository's explicit Apache-2.0 grant for covered Orchard-authored software and technical documentation.
Source visibility alone grants no rights beyond the applicable license terms.
No official binary, supported release, SLA, or maintenance commitment follows from source availability.
Third-party terms and notices remain applicable to their material.
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
