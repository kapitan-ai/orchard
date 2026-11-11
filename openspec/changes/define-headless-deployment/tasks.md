## 1. Contract And Documentation

- [x] 1.1 Add the headless deployment definition to `SPEC.md` §2.3, distinct from the §11.8 headless platform profile, citing this change. Rebase onto `cross-surface-authorization-contract` if it lands first.
- [x] 1.2 Add a `SPEC.md` §7.1 note that, when the Console is disabled, the Operator and Admin APIs are the remote management surface and Controller-host `orchardctl` keeps its §11.9 local authority for unmigrated families.
- [x] 1.3 Add a Headless Deployment entry to `docs/glossary/CONTEXT.md`, distinct from the Linux Controller Profile entry.
- [x] 1.4 Add `docs/headless-mode.md` with the definition, the credential rules, the production-release-only limit, and the headless capability inventory from `design.md` D4, and link it from `docs/operator-journey.md`.
- [x] 1.5 Add the inventory-update rule to the Review Gates section of `docs/process.md` and the checklist in `.github/pull_request_template.md`, so reviewers check it on every Operator or Admin API change.
- [x] 1.6 Record Najib's accepted answers to Q1–Q7 (2026-11-11) in `design.md`, synchronize both inventories and their legends, and distinguish accepted-but-unowned `decided` rows from `planned` contracts and remaining `undecided` work.

## 2. Console-Disabled Regression Coverage

Existing coverage already includes per-route `/console` 404s (`OrchardConsole.Auth` tests) and on_mount denial. These tasks target the gaps.

- [x] 2.1 Assert that a Console LiveView reconnect carrying a session marker issued while the Console was enabled is refused after the Console is disabled, and exposes no Console data.
- [x] 2.2 With the Console disabled, assert that the Developer Portal session, key list, mint, and revoke flows still work.
- [x] 2.3 With the Console disabled, assert that `GET /ops/v1/nodes` on a Standby Controller returns `503 controller_standby`, and that `GET /health/ready` and `GET /ops/v1/cluster` behave as with the Console enabled.
- [x] 2.4 Assert that Console Basic Auth credentials on an Operator API route, and a Portal session cookie alone on an Admin API route, both return `401 invalid_api_key` with no data on a Console-disabled Controller.
- [x] 2.5 Extend existing Console auth, Portal, and Operator API test files instead of adding new ones where they already cover the route.

## 3. Open Items Outside This Change

- [ ] 3.1 Decide whether a Console-disabled Controller should stop supervising `OrchardConsole.ModelHubDownloadCoordinator` to save footprint, and if so open a separate change.
- [ ] 3.2 Open follow-up changes for the `local_cli`, `planned`, and `decided` inventory rows in dependency order: request details after the redaction decision, Node lifecycle actions with Action Previews, then Admin API governance after `cross-surface-authorization-contract` implements its shared fences, retained-writer ledger, and audit surface. Follow Milestone 8's Linux Controller/external Postgres/admitted macOS Node topology while retaining macOS testing; no single-host Ubuntu appliance or support claim.
- [ ] 3.3 Before any MCP work, specify and implement a server-enforced read-only cluster role with the required `SPEC.md` §10.4 and management API admission amendments. Read tools must omit request content by default; an `operator` token plus a read-only tool list is insufficient. Then specify the Q2 client-side stdio adapter over `reverse_proxy` or `direct_https`. Any later writes need an explicit allowlist, their Operator API route and Action Preview, and human approval bound to action, target, and expiry; use `operator`, not `admin`, and keep D5's admin actions and invite URLs out without a separate reviewed change.
- [ ] 3.4 Implement Q7's source-dev switch in shared dev config for `bin/dev` and `bin/dev-controller`, using the strict `ORCHARD_CONSOLE_ENABLED` parser and defaulting to on. In that change, amend `SPEC.md` §2.3 and this change's spec delta (or its synced successor) to replace "always enables" while retaining "SHALL NOT be described as a Headless Deployment". Verify routing and API-only operation, not production credential posture; Portal onboarding needs `reverse_proxy`.
- [ ] 3.5 Specify and implement Q6's Portal User Admin API list, inspect, create, invite or reissue, and disable routes only after the shared fences, retained-writer ledger, and audit surface in `cross-surface-authorization-contract` are implemented. Amend `SPEC.md` §7.4a and the Admin route contract in that follow-up; document that disable ends sessions, not minted API Keys, and keep invite URLs out of MCP.
- [ ] 3.6 Specify and implement Q5's offline bundle-preparation command, turning a Hugging Face snapshot into an Orchard Artifact Bundle without the Console. Implement the already-specified `POST /admin/v1/models/import` (`source_type: local_path`, Controller-host path) in a later slice; only a Hugging Face download API is deferred, and Model Hub search/download remain Console-only.
- [ ] 3.7 Resolve the request-list contract in a SPEC amendment that names it before marking the inventory row `planned`; §7.3.1 currently names details, not listing or browsing. Retain the separate request-details capture-mode redaction decision.
- [ ] 3.8 Close the no-headless-path model deprecate and retire journeys under `SPEC.md` §7.4.1, including their consequence for the complete retire-then-delete journey. A local delete command alone does not close that gap.
- [ ] 3.9 Close the no-headless-path API Client disable containment journey under the service-account management contract, after the shared authorization prerequisites; this remains separate from the first credential family.
- [ ] 3.10 Close the no-headless-path credential list and inspect journey through the first family in `cross-surface-authorization-contract` and `SPEC.md` §§10.11, 11.9, without claiming current remote or MCP coverage.

## 4. Validation

- [x] 4.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate define-headless-deployment --type change --strict --no-interactive`.
- [x] 4.2 Run the full Elixir quality and coverage workflow from `AGENTS.md` for the regression tests in section 2.
- [ ] 4.3 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and replace any generated placeholder prose, such as `Purpose TBD`, in `openspec/specs/headless-deployment/spec.md`.
