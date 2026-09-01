## ADDED Requirements

### Requirement: Controller Release Independence Is Proven From The Assembled Artifact

Validation for Controller release composition or packaged command routing SHALL inspect a real assembled Controller release.
It SHALL prove that the release omits the `orchard_cli` application, contains no CLI library or `OrchardCLI.*` beam, resolves `OrchardCLI.ControllerRPC` to `:non_existing`, loads the Controller-owned private entrypoint, and executes the supported packaged route.
The changed-path classifier SHALL select every portable, provider-neutral, platform, packaging, OpenSpec, and aggregate lane that consumes root release composition, Controller source, CLI compatibility, or payload routing.

#### Scenario: Controller release is assembled

- **WHEN** validation assembles the production Controller release
- **THEN** artifact inspection proves CLI implementation is absent
- **AND** direct and packaged RPC tests prove the Controller-owned entrypoint and unchanged envelope behavior

#### Scenario: Release-composition change is classified

- **WHEN** the root release definition, packaged wrapper, Controller compatibility source, or focused OpenSpec contract changes
- **THEN** dependency classification selects every consuming validation lane
- **AND** the required aggregate gate fails if any selected lane fails or skips
