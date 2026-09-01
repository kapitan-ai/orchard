## ADDED Requirements

### Requirement: Packaged Controller Compatibility Handler Is Controller-Owned

The current local packaged node-command migration baseline SHALL invoke a private Controller-owned compatibility handler without loading the CLI application or any `OrchardCLI.*` module into the Controller release.
The handler SHALL accept the existing list of independently Base64-encoded arguments, SHALL retain the existing closed node-command allowlist, and SHALL emit exactly one bounded `ORCHARDCTL_RPC_V1` envelope.
It SHALL reuse the existing Controller-owned preview, leader authorization, mutation, transaction, audit, mutation-time revalidation, and presentation implementation rather than duplicate domain authority.
Controller-side parsing and rendering in this compatibility path SHALL remain private and transitional and SHALL NOT establish a normal authenticated command-family migration.

#### Scenario: Packaged allowlisted node command executes

- **WHEN** the app-owned wrapper invokes an existing allowlisted node command through the running Controller release
- **THEN** a Controller-owned private entrypoint decodes every argument as data and invokes the existing Controller domain implementation
- **AND** it emits exactly one byte-compatible `ORCHARDCTL_RPC_V1` result envelope
- **AND** no CLI application or `OrchardCLI.*` module is loaded in the Controller release

#### Scenario: Command is outside the packaged allowlist

- **WHEN** the private entrypoint receives enrollment, trust, bootstrap, host lifecycle, terminal custody, or another command outside the existing allowlist
- **THEN** it fails closed with the existing bounded command-not-available result
- **AND** no additional local or remote authority is granted

#### Scenario: Standalone CLI invokes a node command

- **WHEN** the standalone CLI invokes an existing node command
- **THEN** its help, parsing, confirmation presentation, output formatting, database failure behavior, and exit status remain unchanged
- **AND** host-local enrollment and trust routes remain owned by the standalone CLI
