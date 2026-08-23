## 1. Contract and compatibility

- [x] 1.1 Update `SPEC.md` to remove product-licensing observations and state.
- [x] 1.2 Reconcile affected active OpenSpec packages and main specs.
- [x] 1.3 Confirm the public TDD seams before writing behavior tests.
- [x] 1.4 Record that no licensing database schema exists and legacy bundles remain untouched.

## 2. Public behavior tests and implementation

- [x] 2.1 Prove Controller product routes no longer deny useful work based on license state, then remove the HTTP gate.
- [x] 2.2 Prove Console actions and rendering are license-independent, then remove Console gates and status UI.
- [x] 2.3 Prove first-run and CLI routing no longer expose activation or status, then remove the license command.
- [x] 2.4 Prove Node Agent startup and runtime/model paths are license-independent, then remove enforcement.

## 3. Shared and operational removal

- [x] 3.1 Remove shared validation, local-store, cache, status, and application wiring.
- [x] 3.2 Remove license identity and tracking from health, logs, Sentry, telemetry, and support output while retaining secret redaction where independently useful.
- [x] 3.3 Remove licensing configuration, packaging defaults/hooks, documentation, fixtures, and licensing-only tests.
- [x] 3.4 Verify legacy licensing environment variables are ignored and legacy bundle files are not read, changed, or deleted.
- [x] 3.5 Verify unrelated auth, authorization, governance, quotas, accounting, billing, and legal attribution remain intact.

## 4. Validation and review

- [x] 4.1 Run strict OpenSpec validation for `remove-product-licensing`.
- [x] 4.2 Run `mise exec -- mix format`.
- [x] 4.3 Run `mise exec -- mix compile --warnings-as-errors`.
- [x] 4.4 Run `mise exec -- mix credo --strict`.
- [x] 4.5 Run `mise exec -- mix dialyzer`.
- [x] 4.6 Run `mise exec -- mix test`.
- [x] 4.7 Run `mise exec -- mix test --cover`.
- [x] 4.8 Run applicable packaging and CLI wrapper tests.
- [x] 4.9 Run RepoPrompt review/Oracle and No Mistakes on the final diff.
- [x] 4.10 Re-run residual product-license searches and inspect every remaining match.
