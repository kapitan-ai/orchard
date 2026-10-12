## ADDED Requirements

### Requirement: Linux Node Candidate Defines No Distribution Artifact

The experimental `ubuntu_24_04_x86_64_node` candidate SHALL satisfy the no-artifact, not-yet-operable source-development target path, no-build source qualification, future-package approval, and no-publication rules in the `SPEC.md` §11 preamble, consistent with §11.0.
Earlier package-first candidate material SHALL NOT authorize a Linux Node package build, installation, or distribution goal.
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
