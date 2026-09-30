## ADDED Requirements

### Requirement: Linux Node Candidate Defines No Distribution Artifact

The experimental `ubuntu_24_04_x86_64_node` candidate SHALL define no distribution profile, package, container image, or other deployment artifact.
Its current installation path SHALL be source development consistent with `SPEC.md` §11.0.
A future Linux Node package, including any fixed filesystem layout, package-created service identity, package-owned service unit, closed dependency manifest, or air-gapped media, SHALL require a fresh accepted OpenSpec proposal, a separate implementing pull request, and the accountable product owner's approval before any artifact is built.
Earlier package-first candidate material SHALL NOT authorize a Linux Node package build, installation, or distribution goal.
Candidate source installation or qualification evidence SHALL NOT authorize publication, a release, or a Linux support claim.
Candidate work SHALL NOT alter the Distribution Pause Control or assemble `Orchard.app` or a DMG.
This requirement changes `SPEC.md` §11.

#### Scenario: Contributor proposes a Linux Node Debian package

- **WHEN** a contributor proposes building a Debian package for the candidate
- **THEN** the work requires a fresh accepted OpenSpec proposal and a separate implementing pull request with owner approval
- **AND** no package artifact is built under this candidate contract

#### Scenario: Candidate qualification completes

- **WHEN** candidate source-development qualification evidence is recorded
- **THEN** no release, publication, or distribution channel is created
- **AND** the Distribution Pause Control remains unchanged
