## ADDED Requirements

### Requirement: Orchard Has One Product-Version Authority

Orchard SHALL store Product Version in a root `VERSION` file containing exactly one ASCII SemVer line and one terminal newline, with no comments, surrounding whitespace, or build metadata.
Every first-party Mix project, runtime report, shell distribution input, Swift app input, release filename, and tag validator SHALL derive from that file or fail exact validation against it.
Independent internal component package versions SHALL NOT be treated as Orchard Product Version values.
This requirement refines `SPEC.md` §13.1 without changing the current Product Version.

#### Scenario: First-party version surface drifts

- **WHEN** a first-party Mix application, runtime report, or packaging input exposes a Product Version different from root `VERSION`
- **THEN** normal and release validation fail before a governed artifact is promoted or published

#### Scenario: Canonical version syntax is invalid

- **WHEN** root `VERSION` contains comments, extra whitespace, build metadata, more than one line, or a nonconforming Product Version
- **THEN** repository validation rejects the value without rewriting it

### Requirement: Product Version Changes Only At Release Boundaries

Before Orchard 1.0, active development versions SHALL use `0.Y.Z-dev`, ordered Release Candidates SHALL use `0.Y.Z-rc.K`, and final releases SHALL use `0.Y.Z`.
Release Candidate counter `K` SHALL start at `1`, increase consecutively for the same base version, and contain no leading zeroes.
At least one Verified Candidate SHALL precede a final release, and a patch SHALL follow the full `-dev`, `-rc.1`, and final sequence.
Ordinary commits and merges SHALL retain the current Product Version.
After a final release, a separate authorized transition SHALL select the next patch or minor development line, and skipped minor lines SHALL require explicit transition intent.
A transition to `1.0.0-dev` SHALL require a separately accepted apex compatibility decision.
This requirement refines `SPEC.md` §13.1.

#### Scenario: Ordinary feature merge lands

- **WHEN** a feature, fix, documentation, or review commit lands without approved release-transition intent
- **THEN** Orchard retains the current Product Version and uses Build Provenance to distinguish the commit

#### Scenario: Patch release is prepared

- **WHEN** Orchard prepares `0.Y.(Z+1)` after a final `0.Y.Z` release
- **THEN** the patch follows `0.Y.(Z+1)-dev`, at least one ordered release candidate, and `0.Y.(Z+1)` final without reusing an earlier version or tag

### Requirement: Version Transitions Require Reviewed Machine-Readable Evidence

Each Product Version change SHALL occur in a dedicated transition pull request that adds exactly one append-only machine-readable transition record for the target version.
The record SHALL identify schema version, from and to versions, transition kind, authorization pull request, reason, Current Release Line, Previous Supported Release Line, one fixed Release Channel, and an Apple build-number allocation reference when an app is included.
Validation SHALL require exact agreement with the version diff, an allowed transition, unused target version, one fixed Release Channel, and required compatibility declaration.
Authorization SHALL bind to the exact reviewed head revision through approved repository review protection or a cryptographically signed approval record whose signer is trusted by repository policy.
A submitter-authored approval string in the transition record SHALL NOT establish authorization.
Any signed-approval fallback SHALL use a canonical detached envelope that binds transition-record digest, exact head commit, target version, signer key identifier, issue time, expiry, nonce, and single-use purpose.
The fallback SHALL use deterministic serialization, a detached signature, a versioned repository key registry, revocation checks, and a proved append-only evidence store outside the approved head commit.
Approval validation SHALL resolve the signer against a key-registry revision trusted before the transition pull request began.
A transition pull request SHALL NOT change the trust roots used to authorize itself, and key additions, removals, or revocations SHALL require a separate protected trust-administration change approved under the previously trusted registry.

#### Scenario: Version changes without bound approval

- **WHEN** a pull request changes `VERSION` without one matching transition record and approval bound to the exact reviewed revision
- **THEN** normal validation rejects the transition

#### Scenario: Private-repository review protection is unavailable

- **WHEN** the configured GitHub plan cannot enforce the required protected review for the private repository
- **THEN** publication remains disabled until the signed-approval fallback is configured and verified

### Requirement: Product Version And Build Provenance Are Distinct

Orchard SHALL represent Product Version separately from full source commit, build date, Release Channel, Apple build number, toolchain, signing state, artifact digests, and internal component versions.
Two builds with the same Product Version SHALL remain distinguishable through immutable Build Provenance without requiring a Product Version bump.
Governed provenance SHALL use the full source commit rather than only an abbreviated Git SHA.
This requirement refines `SPEC.md` §11.8 and §13.1.

#### Scenario: Two development builds share a version

- **WHEN** two clean commits are built under the same development Product Version
- **THEN** their full source commits and other Build Provenance distinguish them while their Product Version remains equal

### Requirement: Signed Release Tags Match Clean Committed Versions

A governed Orchard release tag SHALL be annotated, cryptographically signed by an authorized release actor, immutable, and bound to one clean committed revision whose root `VERSION` exactly matches the tag.
Before Orchard 1.0, RC tags SHALL use `v0.Y.Z-rc.K`, final tags SHALL use `v0.Y.Z`, and development, unsigned, invalid-counter, moved, deleted, or reused tags SHALL be rejected.
The tag SHALL be created only after the transition pull request merges and required validation passes for the exact commit.
Creating the tag SHALL start candidate construction but SHALL NOT prove that artifacts, a draft, or a Published Release exists.
Candidate identity SHALL consist of the signed tag, full source commit, and one Release Channel declared by the transition record.
One tag SHALL produce at most one Candidate Manifest for that channel, and a channel change SHALL require a new Product Version and tag.

#### Scenario: Tag and committed version disagree

- **WHEN** a governed tag encodes a Product Version different from root `VERSION` at its target commit
- **THEN** the candidate lane stops before artifact construction, credential access, drafting, or publication

#### Scenario: Candidate source is dirty or ambiguous

- **WHEN** provenance cannot prove an isolated checkout of the exact tagged commit without tracked changes, index drift, or untracked build inputs
- **THEN** the candidate is ineligible for governed construction or promotion

### Requirement: Candidate And Distribution States Are Separate

Orchard SHALL record candidate state independently as `tagged`, `verified`, `invalid`, or `superseded`.
Orchard SHALL record distribution state independently for each Release Channel as `not_started`, `staged`, `approved`, `partially_delivered`, `delivered`, `partially_published`, `published`, or `withdrawn`.
Draft SHALL be a publication-surface state rather than a candidate state, and failed SHALL be an attempt outcome rather than a candidate state.
A valid unpublished RC MAY be superseded by a later RC, while a Published Release SHALL only be withdrawn or followed by a new release and SHALL NOT be superseded in place.

GitHub surface state SHALL be `absent`, `draft`, `non_draft`, or `withdrawn`.
Amore surface state SHALL be `absent`, `staged`, `restricted_live`, `general_live`, or `withdrawn`.
Internal recipient-delivery state SHALL be `absent`, `staged`, `delivered`, or `withdrawn` and SHALL follow `absent -> staged -> delivered -> withdrawn`.
The `trial` channel SHALL allow GitHub only through `absent -> draft -> withdrawn` and Amore only through `absent -> staged -> restricted_live -> withdrawn`, and a trial GitHub draft SHALL NOT become non-draft.
The `pilot` channel SHALL allow GitHub only through `absent -> draft -> non_draft -> withdrawn` and Amore only through `absent -> staged -> restricted_live -> withdrawn`.
The `release` channel SHALL allow GitHub only through `absent -> draft -> non_draft -> withdrawn` and Amore only through `absent -> staged -> general_live -> withdrawn`.
Failed attempts and unavailable observations SHALL produce authenticated attestations without advancing surface state.
Every surface transition SHALL require the actor authorized for that surface and an atomic compare-and-swap append against the unique current attestation-chain head, and stale or concurrent forks SHALL fail closed.
Transitions to internal `delivered`, Amore `restricted_live` or `general_live`, and GitHub `non_draft` SHALL require a Verified Candidate or sealed Internal Build Manifest plus every digest-bound approval required by the channel.
GitHub `draft` and Amore `staged` MAY exist before approval, but they SHALL remain staging evidence and SHALL NOT yield successful or partial delivery or publication state until required verification and approval are valid.
An externally observed live target state without those prerequisites SHALL record a fail-closed observation and SHALL NOT advance governed surface or distribution state.

Distribution state SHALL use an ordered total reduction over every reachable channel combination.
Any required withdrawn surface or explicit channel withdrawal SHALL reduce first to `withdrawn`.
An invalid or superseded Candidate SHALL reduce to `withdrawn` when any required surface advanced beyond `absent` and otherwise SHALL reduce to `not_started`.
Before any complete or partial delivery or publication reduction, the Candidate SHALL be `verified` or the Internal Build Manifest SHALL be sealed and every channel-required approval SHALL remain valid.
When those prerequisites are absent, pre-live `draft` or `staged` surfaces SHALL reduce only to `staged`, while any observed live target state SHALL fail closed without changing governed state.
Internal SHALL reduce to `delivered` when its recipient-delivery surface is `delivered`.
Trial SHALL reduce to `delivered` only when GitHub is `draft` and Amore is `restricted_live`.
Pilot SHALL reduce to `published` only when GitHub is `non_draft` and Amore is `restricted_live`.
Release SHALL reduce to `published` only when GitHub is `non_draft` and Amore is `general_live`.
Trial SHALL reduce to `partially_delivered` when exactly one required surface has reached its channel target, while pilot and release SHALL reduce to `partially_published` under the same target-state rule.
Any remaining verified combination with valid digest-bound approval SHALL reduce to `approved`.
Any remaining verified combination with at least one required surface in `draft` or `staged` SHALL reduce to `staged`.
All remaining combinations in which required surfaces are `absent` SHALL reduce to `not_started`.
Any combination outside the channel-specific transition graph or ordered reduction SHALL fail closed without changing state.

#### Scenario: One required trial surface is live

- **WHEN** one restricted surface required by the `trial` channel is live while another remains incomplete
- **THEN** the distribution state is `partially_delivered` and Orchard does not report a Delivered Distribution

#### Scenario: One required publication surface is live

- **WHEN** one surface required by `pilot` or `release` is live while another remains incomplete
- **THEN** the distribution state is `partially_published` and Orchard does not report a Published Release

#### Scenario: Candidate construction fails before sealing

- **WHEN** an infrastructure failure occurs before the Candidate Manifest is sealed without invalidating source identity
- **THEN** Orchard records the failed attempt and may retry construction from the same exact tag

### Requirement: Release Channels Define Complete Distribution Contracts

Each Release Channel SHALL define its eligible Product Version form, intended audience, required artifact set, signing and verification level, publication surfaces, and completion condition.
Each Candidate SHALL have exactly one fixed Release Channel, and the governed build-channel value embedded in every artifact SHALL exactly match it.
Exact-byte Promotion SHALL occur only within that channel, and a channel change SHALL require a new Product Version and tag.

The `internal` channel SHALL accept development, RC, or final versions and SHALL require the selected installable artifact, checksum, build manifest, validation summary, and component inventory, plus all `SPEC.md`-required sidecars when a DMG is included.
The `internal` channel SHALL require no GitHub Release or Amore publication and SHALL become Delivered when exact intended recipients can retrieve the recorded bytes.
An untagged development build in the `internal` channel SHALL be an Internal Build rather than a Candidate and SHALL use a commit-bound Internal Build Manifest containing Product Version, full source commit, channel, artifact identities, validation summary, component inventory, and any Apple build-number allocation.
An untagged Internal Build SHALL NOT enter Candidate or Candidate Manifest state, while signed RC or final internal builds SHALL use the Candidate path.
Internal Build delivery SHALL produce signed, hash-chained Internal Build Attestations that reference the Internal Build Manifest digest and use the same append-only evidence-store and signer-verification guarantees as Candidate State Attestations.

The `trial` channel SHALL accept RC versions for one named time-bounded evaluator engagement and SHALL require a signed and notarized DMG, release notes, DMG checksum, before and after signing manifests, Candidate Manifest, compatibility report, SPDX SBOM, and State Attestation evidence.
The `trial` channel SHALL require a private GitHub draft record and an access-restricted Amore delivery of the same candidate and SHALL become Delivered rather than Published when both are complete.

The `pilot` channel SHALL accept RC versions for named design partners or controlled production-like rollout and SHALL require the same distribution set as `trial`.
The `pilot` channel SHALL become Published only when a non-draft private GitHub Release and access-restricted Amore delivery contain or reference the exact approved candidate.

The `release` channel SHALL accept final versions for generally available Orchard customer distribution and SHALL require the same distribution set as `trial`.
The `release` channel SHALL become Published only when general Amore delivery is live and the private GitHub Release is non-draft for the exact approved candidate.
The workflow SHALL publish through Amore first, verify its live state and digest, and publish the matching GitHub Release last.

Native PKG SHALL NOT be a governed current artifact.
Adding it or another distribution artifact type SHALL require a fresh accepted OpenSpec proposal and a separate implementing pull request before any channel may include it.
Trial, pilot, and release publication SHALL remain disabled until live capability checks prove the required Amore audience, idempotency, digest-inspection, and exact-byte promotion behavior.

#### Scenario: Required channel artifact is absent

- **WHEN** a Release Channel requires an artifact or evidence item that is absent
- **THEN** the distribution remains incomplete and unpublishable

#### Scenario: Amore cannot enforce a restricted audience

- **WHEN** live capability checks cannot prove the audience restriction required by `trial` or `pilot`
- **THEN** the affected publication lane remains disabled until an alternative surface is accepted

### Requirement: Governed Artifacts Are Promoted Without Mutation

Orchard SHALL promote only final verified artifact bytes whose identities are sealed after applicable signing, notarization, stapling, mounted verification, checksum generation, and compatibility verification.
Drafting, uploading, approving, and publishing SHALL reuse those exact bytes and SHALL NOT rebuild, resign, repackage, or otherwise replace them.
Failures before manifest sealing MAY retry construction from the exact tag, while failures after sealing MAY retry only with the preserved exact bytes.
Any post-seal digest change SHALL make the candidate invalid and require a new Product Version and tag.
This requirement adds immutable-promotion behavior beneath `SPEC.md` §11.3.

#### Scenario: Artifact changes after sealing

- **WHEN** an artifact digest differs between Candidate Manifest sealing and upload or publication
- **THEN** promotion fails and Orchard requires a new candidate rather than silently replacing the artifact

### Requirement: Candidate Manifest Governs Cross-Artifact Identity

Each Verified Candidate SHALL produce one immutable, versioned, canonically serialized Candidate Manifest after final artifact verification.
The Candidate Manifest SHALL record Product Version, signed tag, full source commit, Release Channel, transition-record digest, Current and Previous Supported Release Lines, Apple versions, required artifact matrix, signing and notarization results, helper provenance, SBOM digest, validation-result digests, and identity evidence for every governed artifact.
The Candidate Manifest SHALL exclude itself from its artifact collection and SHALL receive its own SHA-256 after serialization.

Every distributable file SHALL record a path-independent logical name, byte size, media or artifact type, and SHA-256 over exact bytes.
Every governed directory tree SHALL record a canonical JSON tree sorted by bytewise relative path with entry type, normalized permission mode, regular-file size and digest, and exact symlink target.
Canonical tree identity SHALL exclude timestamps, user IDs, group IDs, and machine-local paths.
Orchard app identity SHALL cover every bundled file, while signing manifests SHALL remain required evidence without replacing complete tree identity.
Every included runtime, staged payload, app, DMG, filename, manifest, sidecar, and SBOM SHALL agree with the candidate identity.

Later approval, attempt, upload, surface-observation, withdrawal, and publication events SHALL produce authenticated append-only State Attestations that reference the Candidate Manifest digest.
Each State Attestation SHALL use deterministic canonical serialization, identify the actor and signer key, record transition type, timestamp, Release Channel, stable surface identifiers, and previous-attestation digest, and carry a detached signature verified against the versioned release key registry.
The chain SHALL be mandatory after the first attestation and SHALL reside in a proved append-only evidence store that rejects overwrite and deletion.
Every append SHALL atomically compare the referenced previous-attestation digest with the unique current chain head and SHALL fail on a stale or conflicting head.
Candidate Manifests and State Attestations SHALL NOT contain credentials, secrets, DSNs, keychain names, machine-local paths, or workflow session identifiers.
An optional mutable current-state projection SHALL NOT count as audit evidence.

#### Scenario: Directory artifact lacks canonical identity

- **WHEN** a staged payload, OTP release, or app bundle lacks the required canonical tree identity
- **THEN** the candidate remains unverifiable and cannot become a Verified Candidate

#### Scenario: Candidate Manifest identity is calculated

- **WHEN** final artifact identity and verification evidence is complete
- **THEN** Orchard serializes the Candidate Manifest without a self-entry, calculates its digest, and uses that digest in every later State Attestation

### Requirement: Apple Bundle Versions Follow A Deterministic Global Mapping

`CFBundleShortVersionString` SHALL use the numeric `X.Y.Z` base of Product Version.
`CFBundleVersion` SHALL use one positive decimal integer in the safe range `1..9999` allocated by the protected Apple Build Number Allocator in an append-only allocation record.
The number SHALL increase globally for bundle identifier `com.orchard.app` across all Release Channels, marketing versions, hotfixes, major-version transitions, and distributed Internal Builds.
A retry of the same exact Candidate or Internal Build SHALL reuse its allocated number, and a new Candidate or distributed app build SHALL consume a new number.
Git SHA, date, workflow identity, and rerun count SHALL remain separate Build Provenance and SHALL NOT be used as `CFBundleVersion`.
Before allocating the first governed number, implementation SHALL inspect any historically distributed app and seed above the highest observed value.
Allocation SHALL use merge-time serialization and uniqueness checks, and app distribution SHALL stop before `9999` is exhausted until an accepted migration defines and validates a replacement Apple-safe mapping.
This requirement adds Apple release identity beneath `SPEC.md` §11.3.

#### Scenario: Prerelease app is assembled

- **WHEN** Orchard assembles an app for `0.Y.Z-rc.K`
- **THEN** its marketing version is `0.Y.Z`, its globally allocated build number is recorded, and prerelease identity remains in the tag, channel, manifest, and provenance

#### Scenario: Historical Apple build maximum is unknown

- **WHEN** implementation cannot prove that the next allocated number exceeds every historically distributed `com.orchard.app` build
- **THEN** app publication remains disabled

### Requirement: Internal Helpers Retain Independent Provenance And Candidate SBOM Evidence

Internal Python helper package versions SHALL remain independent from Product Version and SHALL NOT imply compatibility through numeric equality.
The Candidate Manifest SHALL record each helper's package name, package version, source commit, source-tree digest, `pyproject.toml` digest, `uv.lock` digest, selected extras, target platform and architecture, installed distribution inventory, and packaged tree or deterministic archive digest.
Every tagged Candidate, including the `internal` channel, SHALL include one SPDX 2.3 JSON SBOM covering first-party components, resolved Elixir dependencies, packaged Python dependencies, Swift package dependencies, and discoverable packaged native libraries and runtimes.
The Candidate Manifest SHALL reference the SBOM by SHA-256, and the SBOM SHALL NOT replace exact artifact or tree identities.
This requirement refines component evidence beneath `SPEC.md` §11.8 and §13.1.

#### Scenario: Helper version differs from Orchard

- **WHEN** a release bundles a helper whose package version differs from Product Version
- **THEN** validation records independent helper provenance and does not report a Product Version mismatch

### Requirement: Normal Validation Enforces Governance Without Publication Authority

Pull-request and ordinary `main` validation SHALL verify root `VERSION`, transition rules, first-party BEAM agreement, packaging mappings, compatibility declarations, glossary and OpenSpec consistency, and affected tests while retaining read-only release permissions.
Normal validation SHALL NOT access release credentials or mutate tags, assets, GitHub Release state, or Amore state.
This requirement adds CI governance beneath `SPEC.md` §11 and §13.1.

#### Scenario: Pull request changes a governed version surface

- **WHEN** a pull request changes Product Version storage, a consumer, transition evidence, packaging metadata, compatibility policy, or a release workflow
- **THEN** CI validates affected invariants without obtaining publication authority

### Requirement: Release Workflows Use Separate Least-Privilege Boundaries

Candidate validation, Candidate or Internal Build construction, Apple build-number allocation, Apple signing and notarization, GitHub drafting, Amore staging, distribution approval, Amore delivery or publication, and GitHub publication SHALL use separate capability boundaries with only the credentials and permissions required for each operation.
Signing, Amore publication, and GitHub publication credentials SHALL NOT coexist in one job.
Distribution approval SHALL bind the Candidate Manifest or Internal Build Manifest digest, Release Channel, Product Version, tag when applicable, required artifact set, approving identity, timestamp, expiry, and single-use intent.
Any changed digest, channel, artifact requirement, or compatibility declaration SHALL revoke approval automatically.
The GitHub Release SHALL become non-draft only after Amore live verification succeeds for the same approved candidate.

Implementation SHALL prove private-repository availability of every proposed GitHub protection before claiming it.
If protected reviewers are unavailable, Orchard SHALL require the signed-approval fallback and separately controlled credential custody.
Unavailable immutable Releases or artifact attestations SHALL NOT block a correctly configured fallback, but Orchard SHALL NOT claim platform-enforced immutability or attestation when the feature is unavailable.
Applicable named role assignment, capability checks, digest-bound approval, and credential protection SHALL complete before trial delivery or pilot and release publication.
Trial delivery and pilot or release publication SHALL NOT degrade to an unrestricted manual workflow.

During Orchard's solo-owner operating phase, the Repository Owner MAY hold the Release Owner, Tag Signer, publication approver, Apple Build Number Allocator, Apple-signing custodian, Amore-publication custodian, GitHub-publication custodian, and release-trust administrator roles.
Each trial, pilot, or release Candidate in that phase SHALL include a signed single-owner exception bound to the exact Candidate Manifest digest and Release Channel.
The exception SHALL be a mandatory `single_owner_exception` State Attestation with deterministic canonical serialization.
Its payload SHALL record schema version, Candidate Manifest digest, Release Channel, consolidated roles, signer identity and key identifier, single-Candidate purpose, issue time, expiry, unique nonce, and acknowledgement of every mandatory compensating control.
Validation SHALL verify the signature against the pre-existing release key registry and current revocation data, SHALL reject malformed, future-issued, or expired validity windows, and SHALL store the exception in the Candidate's append-only attestation chain.
Every exception-dependent transition SHALL revalidate issue time and expiry against the trusted transition time before accessing delivery or publication capability.
Revocation before terminal use SHALL require a later signed revocation attestation and SHALL block delivery or publication.
The authorized delivered, published, withdrawn, invalidated, or superseded transition SHALL atomically consume the exception through the attestation-chain compare-and-swap update, after which it SHALL NOT authorize another transition or Candidate.
Approval, signing, staging, and publication SHALL remain separate actions and capability boundaries even when one Repository Owner performs them.
Hardware-backed signing credentials, pre-existing authorization trust roots, exact-byte verification, least-privilege credential isolation, and immutable evidence SHALL remain mandatory compensating controls.
The absence of an experienced backup SHALL be recorded as a resilience risk in every handoff and SHALL NOT independently block release under a valid candidate-bound exception.
A future custodian or backup SHALL receive authority only through a separately protected trust-administration change.

#### Scenario: Distribution approval is absent or stale

- **WHEN** approval is absent, expired, bound to a different manifest, or revoked by a governed change
- **THEN** delivery and publication credentials remain inaccessible and the distribution remains undelivered or unpublished

#### Scenario: GitHub protection is unavailable

- **WHEN** a required private-repository GitHub protection cannot be configured
- **THEN** trial delivery and pilot or release publication remain disabled until the accepted fail-closed fallback is configured and verified

### Requirement: Release Handoff Retains Exact Evidence And Gates

A release handoff SHALL identify Product Version, full source commit, Release Channel, distribution state, required artifact set, final artifact identities, validation results, capability checks, credential gates, role assignments, and residual risks.
For a tagged Candidate, the handoff SHALL additionally identify signed tag, transition-record digest, Current and Previous Supported Release Lines, Candidate Manifest digest, Candidate State Attestations, signing and notarization outcomes, mounted verification results, SBOM digest, and per-surface state required by its channel.
For an untagged Internal Build, the handoff SHALL instead identify the Internal Build Manifest digest and Internal Build Attestations and SHALL mark Candidate-only fields as not applicable.
The handoff SHALL distinguish an Internal Build, tagged Candidate, Verified Candidate, staged distribution, Partially Delivered Distribution, Delivered Distribution, Partially Published Release, Published Release, and withdrawn release.
The handoff SHALL NOT report release readiness when a required capability, role assignment, approval, or evidence item remains unresolved.
This requirement adds operator evidence beneath `SPEC.md` §11 and §13.1.

#### Scenario: Candidate handoff is incomplete

- **WHEN** the handoff cannot identify the exact commit, required artifacts, compatibility evidence, surface states, or remaining gates
- **THEN** Orchard does not treat the candidate as release-ready or Published

### Requirement: Explicit Release Lines Define N And N-1 Compatibility

For `SPEC.md` §13.1, Current Release Line SHALL mean the candidate controller's Orchard `major.minor` line.
Previous Supported Release Line SHALL mean one explicitly enumerated earlier Release Line and SHALL NOT be calculated by subtracting one from the minor version.
Patch and prerelease components SHALL NOT create a new Release Line.
The Current and Previous Supported Release Lines SHALL fulfill the existing symbolic `N` and `N-1` guarantee.

The first governed `0.5` release SHALL select `0.4` as its Previous Supported Release Line but SHALL still pass exact compatibility tests because historical tagging alone does not prove support.
Each candidate SHALL attest Current and Previous Supported Release Line support only after the required controller and Node Agent compatibility suites pass.
The bundled worker SHALL match the Node Agent Product Version required by `SPEC.md`, while its Python package version remains independent provenance.
Release validation SHALL fail when the declaration is absent, contradictory, narrower than the apex guarantee, or unsupported by tests.
Current numeric minor arithmetic in `Orchard.Upgrade` SHALL remain unchanged until the corresponding `SPEC.md` amendment and implementation reconciliation land together.

#### Scenario: A minor line was skipped

- **WHEN** a `0.7` candidate follows an approved `0.5` line without an approved `0.6` line
- **THEN** its Previous Supported Release Line may explicitly name `0.5` rather than inferring `0.6`

#### Scenario: Candidate cannot support the previous line

- **WHEN** a controller candidate cannot pass the required Previous Supported Release Line suite
- **THEN** the release remains blocked unless an accepted change amends `SPEC.md` before that release
