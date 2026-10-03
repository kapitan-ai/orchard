## Why

When the required Linux portable lane fails or runs slowly, the only evidence is the raw job log.
That log does not make the ExUnit seed, per-command outcome, elapsed time, lockfile identity, or cache state easy to find, and copying raw output into an artifact would risk exposing credentials, DSNs, Peer Grant material, and local paths.

## What Changes

- Add a bounded, allowlisted report to the Linux portable validation lane and upload it as a short-lived workflow artifact.
- Record source and run identity, public runner image, the configured toolchain and the versions the installed runtimes report, the numeric PostgreSQL server version, committed lockfile identity before and after setup, the existing Dialyzer PLT cache result and key digest, and each lane command's label, exit status, and elapsed time.
- For test commands, record only the seeds, totals, and coverage totals the commands already print, plus bounded failure identities. Never record assertion payloads, passing-test names, or raw output.
- Publish the report only after validation, bounds, and redaction succeed, so an unfinalized report is never uploaded.
- Treat interrupted, cancelled, unrecognized, or incomplete reporting as `unknown`, never success, and treat a missing artifact as unknown.
- Keep every existing lane command, argument, order, exclusion, fail-fast stop, host guard, setup command, cache, trigger, and gate semantic unchanged. Reporting can never change a command's exit status.

No `SPEC.md` change is required.
The report adds diagnostics to the required validation defined by the accepted `portability-validation` specification. It changes no product behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `portability-validation`: Adds diagnostic reporting for the Linux portable lane without changing lane selection or aggregate gate semantics.

## Impact

- `scripts/test-linux-portable-core.sh` gains an opt-in reporting mode that the workflow enables. Without it, the script behaves exactly as before.
- `.github/workflows/required-validation.yml` gains non-failing report and read-only probe steps, an identifier on the existing Dialyzer cache step, and a pinned artifact upload in the Linux portable job.
- The changes job runs a new stub-driven regression proof.
- The required gate name, the exact required-or-skipped evaluation, the paused distribution control, and the MLX dependency pins are untouched.
