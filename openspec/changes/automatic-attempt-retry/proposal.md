# Automatic attempt retry contract on a different Node (#164)

## Why

`SPEC.md` requires at most one automatic retry before externally meaningful output, but the Controller currently schedules and dispatches only once and persists only `inference_turn:t1:a1`.
PR #162 merged `docs/decisions/0019-one-request-bounded-alternate-node-retry.md` and settled the logical Request versus Inference Attempt model, Output Commitment, retry taxonomy, capacity sequencing, hard prior-Node exclusion, evidence, breaker, and metric contracts.
Issue #120 is closed, so terminal-conformance classification is no longer an open prerequisite.
Implementation remains blocked until this OpenSpec package and the accompanying `SPEC.md` reconciliation are accepted.

## What changes

- Keep one logical Request, one admission, one queue grant, one quota reservation, one idempotency identity, one Payload Capture Mode, and one absolute deadline across at most two Inference Attempts.
- Keep `Orchard.Dispatch.RequestDispatcher` a single-target, single-attempt primitive.
- Make `Orchard.Inference.RequestOrchestrator` own the bounded retry decision and second attempt.
- Define Output Commitment before public handler or serializer delivery for text, tool-call, and structured-output deltas.
- Require a closed allowlist and fail-closed gates before retry.
- Require attempt 2 to use a fresh scheduler decision with hard exclusion of attempt 1's durable Node identity, reported as `previous_attempt_node_excluded`.
- Keep the per-logical-Request prefix-cache scoring and unmanaged compatibility status-probe budgets unreallocated across attempts.
- Require attempt 1 execution resolution and affirmative capacity release before alternate acquisition.
- Persist append-only attempt evidence under `request_events` and separate logical Request metrics from per-attempt metrics.
- Attribute breaker-eligible failures to the Node or placement that produced each actual attempt.
- Unify caller disconnect as cancellation across pre-dispatch, capacity-gate, and runtime-drain phases.

## Out of scope

- More than two attempts.
- Same-Node redispatch presented as Automatic Attempt Retry.
- Queue re-entry after `request_step.started`.
- Operator Retry or distributed-cohort retry.
- A second Request row or a new attempt table.
- A new Request FSM state.
- Durable capacity permits or persisted claim tokens.
- Automatic recovery of in-flight attempts after Controller restart.
- A new public `no_alternative_node` error.
- Circuit-breaker threshold, window, suppression, or clear-path changes.
- Retrying Runtime Endpoint terminal-conformance failures.

## SPEC.md impact

This change reconciles:

- §3.6 and §3.7.1 for Output Commitment, two attempt identities, the bounded `running -> dispatching` re-entry edge without a new Request state, ordering, and durable evidence.
- §4.6.2 and the active `controller-dispatch-capacity-authority` delta for observable idempotent release, release-before-acquire, and the no-queue-re-entry boundary after attempt start.
- §5.3 for one quota reservation and terminal reconciliation.
- §§5.4-5.9 for the queue boundary, hard Node exclusion, bounded retry algorithm, original deadline, cancellation, and public outcomes.
- §5.10 for per-attempt breaker attribution and the eligible failure-class mapping that excludes ordinary capacity scarcity.
- §7.3.5 for the `previous_attempt_node_excluded` scheduler rejection reason code.
- §7.5.3 for keeping the `ScorePrefixCache` caps per logical Request across both attempts.
- §9.1 for bounded attempt and retry metrics.
- §§12.1-12.4 and §12.7 for Node, worker, load, timeout, cancellation, and supportability behavior.
- Milestone 4 delivery and acceptance language.

## Delivery state

Issue #164 owns this contract and OpenSpec package.
Parent objective #121 owns the complete Automatic Attempt Retry outcome.
Implementation is split into blocker-linked GitHub tickets under #121 and must follow their fresh-context acceptance criteria.
