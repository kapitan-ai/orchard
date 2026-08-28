## 1. Contract and planning

- [x] 1.1 Record the accepted retry decision in `docs/decisions/0019-one-request-bounded-alternate-node-retry.md` through merged PR #162
- [x] 1.2 Reconcile Output Commitment, attempt ordering, absolute deadline, quota, queue, exclusion, capacity, breaker, metric, and failure contracts in `SPEC.md`
- [x] 1.3 Update glossary terms from target language to normative language
- [x] 1.4 Author this OpenSpec package with proposal, design, and requirement deltas
- [x] 1.5 Validate the package strictly and review it for placeholders or duplicated apex prose
- [x] 1.6 Publish blocker-linked agent-ready implementation tickets for parent objective #121

## 2. Absolute deadline and durable attempt evidence

- [x] 2.1 Persist one `requests.timeout_at` at Request creation and derive every later budget from it
- [x] 2.2 Add an immutable attempt context with closed attempt, commitment, retry, release, and execution-resolution vocabularies
- [x] 2.3 Enrich inference-turn terminal result maps without introducing an attempt table
- [x] 2.4 Validate enriched attempt results while preserving readability of existing request events
- [x] 2.5 Normalize runtime, model-load, capacity, cancellation, deadline, terminal-conformance, and unknown source failures to the stable §8.2 durable vocabulary
- [x] 2.6 Extend restricted-capture sanitization so closed attempt evidence remains durable under `none` and `metadata`
- [x] 2.7 Prove capture policy does not retain raw targets, messages, content, or arguments outside the allowed mode

## 3. Typed single-attempt dispatcher outcome and release acknowledgement

- [x] 3.1 Return a typed dispatcher outcome with identity, acceptance, events, failure, execution resolution, release outcome, and timing
- [ ] 3.2 Make allocation release distinguish released, already released, not applicable, and unresolved
- [ ] 3.3 Preserve idempotent defensive cleanup without converting authority failure into confirmed release
- [ ] 3.4 Preserve quarantine for unresolved accepted execution
- [ ] 3.5 Keep the dispatcher single-target and single-attempt

## 4. Output Commitment and event isolation

- [x] 4.1 Add a pure monotonic Output Commitment classifier
- [x] 4.2 Commit on non-empty text and stable tool-call identity
- [ ] 4.2a Commit on future content-bearing structured output
- [x] 4.3 Keep accepted, progress, usage, model-load, empty text, and terminal events uncommitted
- [x] 4.4 Record commitment before public handler or serializer delivery
- [x] 4.5 Buffer pre-commit attempt events, flush earlier events before a committing event, expose a safe discard seam, and flush the final uncommitted attempt in order
- [ ] 4.5a Discard attempt 1 events when attempt 2 is integrated
- [x] 4.6 Preserve text-specific `first_token_at`

## 5. Closed failure taxonomy and cancellation

- [x] 5.1 Normalize every failure row in `docs/decisions/0019-one-request-bounded-alternate-node-retry.md` into a closed retry classification
- [x] 5.2 Require both runtime `retryable: true` and an allowlisted transient code
- [x] 5.3 Keep terminal-conformance, persistence, handler, serializer, orchestration, unknown, and deterministic failures non-retryable
- [x] 5.4 Apply the attempt 1 decline precedence and the attempt 2 `retry_exhausted` rule with caller cancellation taking precedence
- [x] 5.5 Unify caller disconnect as cancelled across all dispatch phases and both public APIs

## 6. Hard prior-Node exclusion

- [ ] 6.1 Extend scheduler contracts with hard `exclude_node_ids`
- [ ] 6.2 Filter excluded Node identities before tiering, ranking, scoring, and prefix-cache scoring
- [ ] 6.3 Record the `SPEC.md` §7.3.5 rejection reason code `previous_attempt_node_excluded` in scheduler explanations
- [ ] 6.4 Make admitted single-target scheduling fail when its Node is excluded
- [ ] 6.5 Recheck the selected Node in the orchestrator before dispatch
- [ ] 6.6 Keep the §7.5.3 `ScorePrefixCache` caps per logical Request so attempt 2 uses only their unconsumed remainder and otherwise ranks fail-open
- [ ] 6.7 Prove alternate scheduling runs no second compatibility status-probe wave and records `no_alternative_node` on that branch

## 7. Breaker attribution prerequisite

- [x] 7.0 Implement the durable Node and placement breaker foundation separately through #296 and `node-placement-circuit-breaker-foundation`
- [x] 7.1 Attribute each actual breaker-eligible failure to its producing Node or placement using the `SPEC.md` §5.10 eligible failure-class mapping, excluding `capacity_rejection`
- [x] 7.2 Make attempt 1 breaker effects durable and visible before alternate scheduling
- [x] 7.3 Prove retry decisions and declined retries add no breaker events
- [x] 7.4 Preserve existing breaker thresholds, windows, suppression durations, and Operator clear behavior

## 8. Bounded orchestrator retry

- [ ] 8.1 Run attempt 1 and at most one attempt 2 under one logical Request
- [ ] 8.2 Preserve one admission, queue grant, quota reservation, idempotency scope, capture snapshot, and deadline
- [ ] 8.3 Require resolved execution and affirmative release before alternate scheduling or acquisition
- [ ] 8.4 Run the fresh alternate decision only after attempt 1 breaker effects are durable
- [ ] 8.5 Atomically append attempt 1 terminal evidence and attempt 2 started evidence before dispatch
- [ ] 8.6 Recheck cancellation and deadline at every retry boundary
- [ ] 8.7 Preserve attempt 1's public failure when no alternative exists
- [ ] 8.8 Prevent every post-start failure from queue re-entry

## 9. Attempt and retry metrics

- [ ] 9.1 Emit attempt count and duration metrics with closed labels
- [ ] 9.2 Finalize the retry counter once per logical Request using only valid reason/result combinations
- [ ] 9.3 Prove logical admission, quota, token, outcome, and duration metrics remain once per Request
- [ ] 9.4 Prove metric labels exclude high-cardinality identifiers

## 10. End-to-end acceptance

- [ ] 10.1 Cover attempt 1 transient failure followed by attempt 2 success and failure
- [ ] 10.2 Cover text, tool-call, empty-text, and structured-output commitment boundaries
- [ ] 10.3 Cover no alternative, deadline exhaustion, cancellation races, unresolved release, and same-Node defense
- [ ] 10.4 Cover one quota reservation, idempotent duplicate observation, unchanged capture policy, and attempt-event ordering
- [ ] 10.5 Cover breaker attribution and logical-versus-attempt metrics
- [x] 10.6 Cover Chat Completions and Responses in streaming and non-streaming modes
- [ ] 10.7 Cover terminal-conformance failures as non-retryable

## 11. Quality and completion

- [x] 11.1 Run focused tests for each changed seam
- [x] 11.2 Run `mise exec -- mix format`
- [x] 11.3 Run `mise exec -- mix compile --warnings-as-errors`
- [x] 11.4 Run `mise exec -- mix credo --strict`
- [x] 11.5 Run `mise exec -- mix dialyzer`
- [x] 11.6 Run `mise exec -- mix test`
- [x] 11.7 Run `mise exec -- mix test --cover`
- [x] 11.8 Rerun strict OpenSpec change validation after implementation updates
- [ ] 11.9 After all tickets land, validate all OpenSpec specs strictly and review synchronized main specs for placeholders
