## Context

The required Linux portable lane runs ten commands in order: two Mix test runs and, for each native package, Ruff format, Ruff check, pytest, and pytest with coverage.
Its job log is the only record of what ran, and that log can contain test payloads and environment-derived values.
The report must add diagnostics without changing validation, and must fail closed where the evidence is incomplete.

## Goals / Non-Goals

**Goals:**

- Record bounded, allowlisted facts about each lane command and the run's identity.
- Keep the lane's commands, order, arguments, exit statuses, and gate semantics exactly as they are.
- Never publish raw output, payloads, environment values, or local paths.

**Non-Goals:**

- Reducing suite time, changing test selection, or adding trace, slowest-test, or mode options.
- Adding setup, dependencies, caches, triggers, concurrency, or gate inputs.
- Enforcing lockfile immutability; lockfile changes are reported only.

## Decisions

- **Opt-in mode in the existing lane script.** When `ORCHARD_LINUX_PORTABLE_REPORT_DIR` is unset, each command runs as a plain `set -e` command. When it is set, each command's stdout is passed through `tee` to a private temporary copy, and the command's own status, taken from `PIPESTATUS`, decides whether the script continues. Stderr is not redirected.
- **One write path with a fixed vocabulary.** A repository-owned helper writes every fact. It validates keys and values against narrow patterns and replaces anything else with `invalid` or `unknown`. A POSIX awk parser extracts only seeds, totals, coverage totals, and up to 20 failure identities per command. Absolute or traversing locations become `redacted`, and pytest parameter IDs are removed.
- **Staging and atomic publication.** Facts accumulate in an unpublished staging file. Finalize drops malformed lines and rejects duplicate keys. It replaces any value that contains a nonempty credential-shaped environment value, of any length, or a local path root with `redacted`, and it drops a line whose output-derived app name collides. It then requires every metadata fact to be known, computes the result, and publishes `report.txt` with a single rename. Any redaction makes the report incomplete, so a collision can only produce `unknown`, never exposure. Any failure leaves no published file, so the always-run upload finds nothing.
- **Fail-soft workflow steps.** Report steps use `continue-on-error`. The test step and its failure semantics are unchanged. Cache identity re-evaluates the existing key expression in a separate step, because `actions/cache` exposes only `cache-hit`, and a regression proof keeps both expressions identical.
- **Result semantics.** `success` requires every expected command to exit with status 0, every suite summary to be recognized, every metadata fact to be present, and a job status of `success`. Any recorded nonzero exit is `failure`. Everything else is `unknown`.

## Risks / Trade-offs

- An interrupt delivered only to the lane shell ends the run after the current command. Without the report, bash would continue when the child exits normally. The interrupted run still reports `unknown` and keeps its signal status.
- A hard cancellation or runner loss can leave no artifact. Consumers treat a missing artifact as unknown.
- The cache key digest is re-evaluated after the cache step. Inputs that change between the two steps would be visible through the lockfile identity facts.
- `tee` and the parser add a small per-command cost. That cost is measured with paired stub runs and is not presented as suite savings.
- Output format drift in ExUnit or pytest yields `partial` parsing and an `unknown` result rather than a false success.
