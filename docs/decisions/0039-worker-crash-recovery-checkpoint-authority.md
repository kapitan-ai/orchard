# ADR 0039: Worker crash recovery keeps its checkpoints in Postgres

## Status

Accepted on 2026-10-26 by the accountable product owner.
This supersedes the OpenSpec change `define-worker-crash-recovery` (pull request #386), which this decision removes.

## Context

`SPEC.md` §12.2 requires bounded worker restart backoff and a crash-loop placement breaker.
Two OpenSpec change packages proposed how to persist that state for issue #379:

1. `define-worker-crash-recovery`, merged as a contract in #386, made a protected store on each Node the authority for restart safety and kept only the Controller's projection in Postgres.
   It proposed automatic restart after Node Agent loss, the reason code `worker_crash_loop_open`, and six owner decisions that were never accepted.
2. `worker-crash-recovery`, implemented by pull request #444, keeps one bounded checkpoint per exact placement in Postgres.
   The Node writes it through the authenticated Active Controller and remains the policy and admission authority.

`SPEC.md` makes Postgres the sole persistence and coordination layer, and only the second package has an implementation.

## Decision

- `worker-crash-recovery` governs #379. `define-worker-crash-recovery` is removed rather than amended.
- The scheduler reason for an open crash-loop breaker is `placement_crash_breaker_open`.
- After Node Agent state loss, interrupted or history-bearing placements require explicit operator recovery; clean and new placements load normally.
- Any non-forced unload resets the breaker, alongside operator clear and forced reload.
- A reused PID is not proof that a prior runtime exited.
  Automatic recovery stays blocked until custody proves the recorded runtime incarnation ended, or its host boot ended (`SPEC.md` §12.2.2).
- All-in-one source development runs the Node Agent inside the Controller's BEAM without an enrolled identity, so it calls the same compare-and-set storage in-process.
  The checkpoint table keys on the Node id without a foreign key to `nodes`, because that Node Agent has no inventory row.
  Split roles and packaged hosts keep the identity-bound control path.
- The two-host crash and recovery proof, live mTLS activation, and the Apple Silicon real-model smoke are required before #379 closes, not before #444 merges.

## Consequences

- No second persistence layer exists on Nodes.
- Recovery after an unclean Node Agent loss needs an operator, trading unattended restart for not guessing at runtime state.
- `make dev` loads models without Node enrollment, while split-role source development still needs enrollment and explicit recovery-control endpoints.
- Checkpoint rows are not deleted with a Node row. Nodes are retired by state rather than deleted, so no current path leaves orphaned rows.

## SPEC.md impact

Update required in §12.2.2 for the all-in-one in-process checkpoint path. The PID-reuse rule is already stated there.
