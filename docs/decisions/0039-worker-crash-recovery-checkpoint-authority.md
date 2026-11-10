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
- A successful non-forced `unload` recovery command resets the breaker, alongside operator clear and forced reload.
  An ordinary unload, including one an operator issues outside the recovery command, does not (`SPEC.md` §12.2.2).
- A reused PID alone is not proof that a prior runtime exited.
  Automatic recovery stays blocked until custody proves the recorded runtime incarnation ended, or its host boot ended (`SPEC.md` §12.2.2).
  Custody records a digest of the runtime's launch identity (owner and start time) with its PID, so a live PID whose identity no longer matches proves the recorded incarnation is gone.
  That identity is read with a fixed timezone and locale, and on Linux from start ticks since boot, so a timezone change, a different Node Agent environment, or a wall-clock step cannot make a still-running runtime look replaced.
  Custody without a digest, or a PID whose identity cannot be read, stays unresolved.
  Current-lifetime exit and signalling checks use that same identity.
  Linux reads the effective uid from the status `Uid:` line, matching `ps uid`; directory ownership is not process credentials and can change with dumpability.
  New Linux custody tokens append an `euid` segment to distinguish this identity from the old directory-owner digest.
  Old Linux tokens retain PID nonexistence and host-boot proofs but cannot prove PID reuse, and older readers treat the new segment as unknown custody rather than a mismatching digest on rollback.
  A rolled-back reader can overwrite that unknown token with bare boot evidence during an ownerless interrupted write; rolling forward then requires a host reboot or operator cleanup to resolve that placement.
- Reset shares one 3-second monotonic wait deadline across recovery settling and runtime custody.
  A checkpoint outage returns unavailable within that budget, retaining pending recovery evidence for retry rather than claiming cleanup succeeded.
  Graceful Node Agent shutdown retains its 10-second intentional-stop checkpoint allowance and a 3-second custody deadline measured from the same start, not an additional wait.
- All-in-one source development runs the Node Agent inside the Controller's BEAM without an enrolled identity, so it calls the same compare-and-set storage in-process.
  The checkpoint table keys on the Node id without a foreign key to `nodes`, because that Node Agent has no inventory row.
  The in-process path trusts its caller by being in the same BEAM: it checks that the Node id is well formed but does not consult Node state or enrollment, so it is not equivalent to the certificate path and is configured only for all-in-one source development.
  Split roles and packaged hosts keep the identity-bound control path.
- In all-in-one source development, the Operator API forwards recovery commands for that in-process Node Agent's own identity in-process too.
  The command keeps the same catalog and exact-version checks, audit, Node-side validation, and epoch/revision fencing; any other Node id still requires an enrolled Node and its identity-bound Runtime Endpoint.
- Checkpoints key on the exact runtime model id and version without a reference to the catalog row, so deleting and re-importing a catalog model cannot erase an open breaker or unresolved ownership.
- The two-host crash and recovery proof, live mTLS activation, and the Apple Silicon real-model smoke were required before #379 closes, not before #444 merges.
  On 2026-10-27 the accountable product owner closed #379 after the Apple Silicon real-model proof in all-in-one source development.
  The two-host proof and live mTLS activation were not run, and the proof found #547.

## Consequences

- No second persistence layer exists on Nodes.
- Recovery after an unclean Node Agent loss needs an operator, trading unattended restart for not guessing at runtime state.
- `make dev` loads models without Node enrollment, and an operator can inspect and clear, unload, or reload its placements through the Operator API using the in-process Node Agent's id.
  Split-role source development still needs enrollment and explicit recovery-control endpoints.
- Checkpoint rows are not deleted with a Node row. Nodes are retired by state rather than deleted, so no current path leaves orphaned rows.

## SPEC.md impact

Section §12.2.2 includes the all-in-one in-process checkpoint and operator recovery paths, wall-clock-stable current-lifetime identity checks, effective-uid Linux custody and conservative legacy-token handling, and the shared reset wait deadline distinct from graceful shutdown's checkpoint allowance.
