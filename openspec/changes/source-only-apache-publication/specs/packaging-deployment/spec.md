## MODIFIED Requirements

### Requirement: Source Availability Does Not Imply Public Binary Support

Per `SPEC.md` §11, Orchard's initial publication SHALL be source-only under the repository's explicit Apache-2.0 grant for covered Orchard-authored software and technical documentation, with Copyright 2026 AI Singapore.
Third-party software, models, tokenizers, assets, and other separately licensed material SHALL be excluded from that grant and remain subject to their own terms and notices.
Orchard logos and distinctive brand assets under `apps/orchard_controller/priv/static/images/` and `assets/brand/` SHALL be excluded from that grant, and trademark rights are not granted.
Source availability SHALL NOT be represented as public binary availability or support.
Source visibility alone SHALL NOT grant rights beyond the applicable license terms.
A supported public binary SHALL require an explicit release decision and completion of every applicable build, verification, signing, notarization, stapling, and publication gate.
Initial source publication SHALL NOT provide an official binary, supported release line, SLA, or maintenance commitment.

#### Scenario: Source is available before public binaries

- **WHEN** Orchard source is published without an approved public binary release
- **THEN** the repository states the applicable source license and preserves third-party attribution
- **AND** the grant preserves the stated logo and distinctive-brand exclusions and applicable trademark terms
- **AND** documentation does not promise an official binary, supported release, or support commitment
- **AND** the approved Orchard.app-inside-DMG design remains unchanged
