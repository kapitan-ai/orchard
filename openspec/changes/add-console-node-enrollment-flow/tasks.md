## 1. Contract And Design

- [x] 1.1 Add this OpenSpec proposal, design, tasks, and operator-first-run requirement delta.
- [x] 1.2 Add reusable guided-progress, blocker, automatic polling, one-time secret output, and recovery rules to `docs/DESIGN.md`.
- [x] 1.3 Validate the change strictly before product-code implementation.

## 2. Shared Enrollment Publication Contract

- [x] 2.1 Move non-secret Controller endpoint metadata into a shared module consumed by CLI and Console.
- [x] 2.2 Add a Controller-owned Node Enrollment Bundle builder that creates one `pending_publication` Enrollment and returns the canonical encoded artifact without marking it issued.
- [x] 2.3 Refactor the CLI publication adapter to use the shared builder while preserving owner-only exclusive output and failure reconciliation.
- [x] 2.4 Add focused builder and adapter tests for canonical bundle fields, owner-only CLI publication, Console one-time delivery, and secret exclusion from audit metadata.

## 3. Console Add Node Flow

- [x] 3.1 Add `/console/nodes/new` and an **Add Node** action on the Nodes workspace.
- [x] 3.2 Add the ordered preparation and enrollment form with intended Node name, `general` Pool intent, and bounded expiry.
- [x] 3.3 Add the one-time browser delivery hook, acknowledgement validation, issued transition, output-failure transition, and no-redisplay behavior.
- [x] 3.4 Add the exact target-Mac join command, secure transfer guidance, automatic five-second polling, last-checked time, and manual refresh fallback.
- [x] 3.5 Hand registered Nodes into the existing Node detail and explicit admission review without a manual registration or activation action.
- [x] 3.6 Prefill admission Pool intent when available while preserving execution-time blocker revalidation.

## 4. Verification

- [x] 4.1 Add LiveView tests for discovery, ordered guidance, validation, success, client delivery failure, lost acknowledgement, expiry, revocation, registration polling, and admission handoff.
- [x] 4.2 Add client-hook tests for Blob type, sanitized filename, acknowledgement payload, failure payload, object URL revocation, and memory cleanup.
- [x] 4.3 Run focused domain, CLI, Console, asset, and browser tests.
- [x] 4.4 Run `mise exec -- mix format`, compile with warnings as errors, Credo strict, Dialyzer, the complete test suite, and coverage.
- [x] 4.5 Run strict validation for this change and the complete OpenSpec tree.
- [x] 4.6 Perform browser design QA against the accepted MagicPath v4 flow at matching desktop states and record evidence in the implementation PR rather than a committed transient report.
- [x] 4.7 Obtain independent review of the final diff before handoff.
