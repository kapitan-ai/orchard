## ADDED Requirements

### Requirement: Native App And DMG Distribution Is Paused By A Committed Control

Orchard SHALL keep exactly one committed Distribution Pause Control for the macOS native distribution profile.
Distribution SHALL be treated as active only when that control is a regular repository file that declares exactly one `state` whose value is exactly `active`.
Any other value, a missing, unreadable, or symlinked control, or a duplicated or malformed `state` declaration SHALL be treated as paused.

While distribution is paused, every repository entrypoint that assembles or signs `Orchard.app`, or assembles, notarizes, staples, or publishes a DMG, SHALL refuse before any build, signing, image, credential, or network step and SHALL exit with a dedicated nonzero status that identifies the control and the re-enable procedure.
Help output MAY remain available while paused.
No environment variable, command-line flag, or substituted tool SHALL resume a paused distribution.

While distribution is paused, source development SHALL be the current active Orchard installation path, and documentation SHALL describe native app and DMG distribution as paused rather than removed or currently available.
The approved `Orchard.app`-inside-DMG design, the app-owned service lifecycle, the shared payload, and credential-free signing-contract tooling SHALL remain in the repository as dormant, validated support.

Resuming distribution SHALL require a reviewed pull request that changes the committed control to `active` with the explicit approval of the accountable product owner.
Resuming distribution SHALL NOT by itself satisfy any public binary release decision or release gate.

#### Scenario: A paused app build is attempted

- **WHEN** the committed control declares `state=paused` and an operator or agent runs the app assembly, app signing, or DMG entrypoint with otherwise valid arguments
- **THEN** the entrypoint exits with the dedicated pause status
- **AND** no Swift build, copy, codesign, image, notarization, stapling, or publication tool is invoked
- **AND** no output artifact is created

#### Scenario: The control is missing or malformed

- **WHEN** the control file is absent, a symlink, unreadable, declares `state` more than once, or declares any value other than `active`
- **THEN** distribution is treated as paused and the entrypoints refuse

#### Scenario: An environment override is attempted

- **WHEN** the committed control is paused and the caller sets environment variables that claim distribution is active or point at another control
- **THEN** the entrypoints still refuse with the dedicated pause status
- **AND** no command-line flag exists that resumes distribution

#### Scenario: Help is requested while paused

- **WHEN** a paused entrypoint is invoked with `--help`
- **THEN** it prints usage and exits successfully without building anything

#### Scenario: Distribution is resumed

- **WHEN** a reviewed pull request approved by the accountable product owner changes the committed control to `state=active`
- **THEN** the entrypoints proceed to their existing validation and build behavior
- **AND** every existing release decision and release gate still applies before a public binary is supported
