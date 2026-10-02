## ADDED Requirements

### Requirement: Linux Portable Validation Reporting

The required Linux portable validation lane SHALL publish a bounded diagnostic report as a workflow artifact.
The report SHALL NOT change which commands the lane runs, their arguments, order, exclusions, fail-fast behavior, unsupported-host refusal, setup, caches, triggers, or aggregate gate semantics.
The lane's exit status SHALL be the exit status of its first failing command, and no reporting failure, including a failure to write a warning, SHALL change that status.
The report SHALL contain only allowlisted facts: source, head, base, event, and run-attempt identity; public runner image identity; the configured toolchain and the versions reported by the installed runtimes; the numeric PostgreSQL server version; committed lockfile identity before and after setup; the existing cache result and a digest of its key; and each command's label, exit status, and elapsed time.
For test commands it MAY add seeds and totals the commands already print, coverage totals, and a bounded number of failure identities.
The report MUST NOT contain raw command output, assertion payloads, passing-test enumerations, environment values, credentials, DSNs, cookies, Peer Grant material, or absolute local paths.
The report SHALL be published only after validation, bounding, and redaction succeed, and an unfinalized report MUST NOT be uploaded.
A run that is interrupted, cancelled, missing metadata, or whose suite summary is not recognized SHALL report `unknown`, never success, and a missing artifact SHALL be treated as unknown.

#### Scenario: Lane passes with a complete report

- **WHEN** every lane command exits with status 0, every suite summary is recognized, every metadata fact is present, and the job is neither failed nor cancelled
- **THEN** the report result is `success`
- **AND** the lane and aggregate gate results are decided by the job results exactly as before

#### Scenario: A lane command fails

- **WHEN** a lane command exits with a nonzero status
- **THEN** no later lane command runs
- **AND** the lane exits with that command's status
- **AND** the report records that command as the first failed step with result `failure`

#### Scenario: The run is interrupted or reporting is incomplete

- **WHEN** the lane is interrupted, its suite summary is not recognized, or a metadata fact is missing
- **THEN** the report result is `unknown`
- **AND** the lane exit status is unchanged by reporting

#### Scenario: Finalization fails

- **WHEN** the report cannot be validated, bounded, redacted, or published
- **THEN** no report artifact is uploaded
- **AND** the absence is treated as unknown rather than success

#### Scenario: Command output contains sensitive values

- **WHEN** command output or failure identities contain credentials, DSNs, cookies, grant material, assertion payloads, or absolute paths
- **THEN** none of those values appear in the uploaded report
- **AND** the unmodified output remains only in the existing job log
