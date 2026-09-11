## 1. Operator Retry Slice

- [x] 1.1 Add a cluster-operator-only retry route and server-side write authorization.
- [x] 1.2 Atomically validate an eligible full-capture legacy source, reserve a descendant, cap lineage at three, and preserve the original Request pointer.
- [x] 1.3 Reconstruct only the legacy canonical serialization and reject retained negotiated reasoning evidence fail closed.
- [x] 1.4 Resolve retry capture to the narrower source and current tenant policy, then dispatch the persisted descendant through the existing lifecycle.
- [x] 1.5 Add authorization, tenant isolation, source eligibility, race, capture-lattice, lineage, idempotency, scheduler-handoff, and no-row-on-failure coverage.
- [ ] 1.6 After #327 and prerequisite canonical reasoning work merge and are accepted, implement and test the negotiated-identity proof branch in a separate change.

## 2. Validation

- [x] 2.1 Run strict validation for this change and all OpenSpec changes.
- [x] 2.2 Run the applicable full Elixir quality and coverage workflow.
