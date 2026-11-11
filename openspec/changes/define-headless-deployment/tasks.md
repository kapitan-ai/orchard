## 1. Contract And Documentation

- [x] 1.1 Add the headless deployment definition to `SPEC.md` §2.3, distinct from the §11.8 headless platform profile, citing this change. Rebase onto `cross-surface-authorization-contract` if it lands first.
- [x] 1.2 Add a `SPEC.md` §7.1 note that, when the Console is disabled, the Operator and Admin APIs are the remote management surface and Controller-host `orchardctl` keeps its §11.9 local authority for unmigrated families.
- [x] 1.3 Add a Headless Deployment entry to `docs/glossary/CONTEXT.md`, distinct from the Linux Controller Profile entry.
- [x] 1.4 Add `docs/headless-mode.md` with the definition, the credential rules, the production-release-only limit, and the headless capability inventory from `design.md` D4, and link it from `docs/operator-journey.md`.
- [x] 1.5 Add the inventory-update rule to the Review Gates section of `docs/process.md` and the checklist in `.github/pull_request_template.md`, so reviewers check it on every Operator or Admin API change.
- [ ] 1.6 Record the product owner's answers to Q1 to Q7 in `design.md` as they arrive, and update the inventory's `console_only` and `undecided` entries to match.

## 2. Console-Disabled Regression Coverage

Existing coverage already includes per-route `/console` 404s (`OrchardConsole.Auth` tests) and on_mount denial. These tasks target the gaps.

- [x] 2.1 Assert that a Console LiveView reconnect carrying a session marker issued while the Console was enabled is refused after the Console is disabled, and exposes no Console data.
- [x] 2.2 With the Console disabled, assert that the Developer Portal session, key list, mint, and revoke flows still work.
- [x] 2.3 With the Console disabled, assert that `GET /ops/v1/nodes` on a Standby Controller returns `503 controller_standby`, and that `GET /health/ready` and `GET /ops/v1/cluster` behave as with the Console enabled.
- [x] 2.4 Assert that Console Basic Auth credentials on an Operator API route, and a Portal session cookie alone on an Admin API route, both return `401 invalid_api_key` with no data on a Console-disabled Controller.
- [x] 2.5 Extend existing Console auth, Portal, and Operator API test files instead of adding new ones where they already cover the route.

## 3. Open Items Outside This Change

- [ ] 3.1 Decide whether a Console-disabled Controller should stop supervising `OrchardConsole.ModelHubDownloadCoordinator` to save footprint, and if so open a separate change.
- [ ] 3.2 Open follow-up changes for the `local_cli`, `planned`, and decided `undecided` inventory rows in dependency order: request details after the redaction decision, Node lifecycle actions with Action Previews, then Admin API governance after `cross-surface-authorization-contract`.

## 4. Validation

- [x] 4.1 Run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate define-headless-deployment --type change --strict --no-interactive`.
- [x] 4.2 Run the full Elixir quality and coverage workflow from `AGENTS.md` for the regression tests in section 2.
- [ ] 4.3 After archive or sync, run `OPENSPEC_TELEMETRY=0 mise exec -- npm run openspec -- validate --all --strict --no-interactive` and replace any generated placeholder prose, such as `Purpose TBD`, in `openspec/specs/headless-deployment/spec.md`.
