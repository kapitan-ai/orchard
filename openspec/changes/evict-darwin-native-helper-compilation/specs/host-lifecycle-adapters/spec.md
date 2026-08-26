## MODIFIED Requirements

### Requirement: Platform Native Artifacts Are Isolated

Host adapters that require native platform code SHALL be built and validated only in compatible platform lanes and MUST NOT be unconditional compile dependencies of the portable umbrella.
Darwin terminal-custody and lifecycle helper sources SHALL be owned outside portable OTP applications and compiled only through an explicit macOS host-artifact builder.
The builder SHALL stage each retained helper into the selected `orchard_cli` application `priv` directory for source tests or packaged assembly.
Retained consumers MUST fail closed when a required helper is absent, cannot execute, or returns malformed evidence.
This requirement implements the dependency direction in `SPEC.md` §§1.2, 1.4, 2.5, and 14 without changing the retained macOS lifecycle contract in §11.4.

#### Scenario: Linux portable compile excludes Darwin helper

- **WHEN** the portable umbrella compiles on Linux
- **THEN** Darwin lifecycle and terminal-custody sources are not compiled
- **AND** no Orchard Darwin helper artifact is emitted
- **AND** their absence does not remove platform-neutral Controller, Node Agent, Shared, or CLI modules

#### Scenario: macOS source tests select explicit helpers

- **WHEN** a macOS contributor runs retained lifecycle or terminal-custody tests
- **THEN** the macOS helper builder stages the production helpers and applicable test helper into the test CLI application `priv` directory before Mix tests run
- **AND** the ordinary Mix compiler does not own that build

#### Scenario: packaged CLI contains retained production helpers

- **WHEN** the macOS payload workflow assembles the packaged CLI release
- **THEN** it explicitly builds and stages `orchard-secret-tty` and `orchard-lifecycle-helper`
- **AND** it excludes the test-only helper and native source files
