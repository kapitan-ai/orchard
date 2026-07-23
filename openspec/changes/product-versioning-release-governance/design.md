## Context

Orchard currently reports product version `0.5.0-dev` from first-party OTP application metadata and records Git SHA, build date, and build channel separately through `Orchard.BuildInfo`.
The same product-version literal is repeated in the umbrella and four first-party Mix projects, while the PKG builder reads only the umbrella value.
The app builder receives independent marketing and build values, and no current gate proves that those values agree with the staged payload or PKG identity.
The two bundled Python helpers each use an independent `0.1.0` package version, which is component provenance rather than Orchard product identity.

The live repository state was reverified on 2026-07-23 from commit `b564f90e858820ccfbfaffbe432feb601ae24d67`.
The only live tag is the annotated but unsigned `v0.4.0`, and GitHub has no Release objects.
The private repository's current required CI runs on pull requests and pushes to `main`, validates Elixir and OpenSpec, and has read-only repository permissions.
It does not run on tags, build a governed release set, or manage GitHub Release state.

`SPEC.md` §13.1 requires controller version `N` to support node-agent versions `N` and `N-1`, but it does not define how those symbols map to product SemVer.
The current upgrade implementation treats `N` as a SemVer major and minor line and calculates `N-1` by minor-version subtraction while ignoring patch and prerelease components.
That behavior is executable evidence, but it is not authoritative until the meaning is accepted in `SPEC.md`.

`SPEC.md` §11 requires the DMG distribution set to include release notes, a DMG checksum, and before and after app-signing manifests.
It also assigns final DMG assembly, notarization, stapling, hosting, and publication integration to Amore while retaining nested signing and verification under Orchard control.
The accepted `app-distribution-lifecycle` and `packaging-deployment` capabilities continue to own artifact-specific assembly, verification, and lifecycle behavior.
This change adds product-wide governance without duplicating those contracts.

Primary-source research constrains the proposal without replacing Orchard policy.
SemVer permits prerelease identifiers and treats build metadata as non-precedence provenance.
Apple requires a three-integer `CFBundleShortVersionString` and a numeric `CFBundleVersion` with one to three integer components.
GitHub recommends completing a draft's asset set before publishing an immutable Release and recommends least-privilege workflow permissions.
GitHub protected-environment approvals, immutable Releases, and artifact attestations remain capability gates because availability for this private repository has not been proved.

## Goals / Non-Goals

**Goals:**

- Establish one canonical Orchard product-version authority for every first-party release surface.
- Define a pre-1.0 release-transition policy that does not use product-version bumps as per-commit build identity.
- Bind a governed release to an exact version, signed tag, clean commit, channel, compatibility declaration, and immutable manifest.
- Fail closed when runtime, PKG, staged payload, app, DMG, filenames, manifests, sidecars, or publication surfaces disagree about release identity.
- Define deterministic Apple marketing-version and globally monotonic build-version constraints for the Orchard app bundle identifier.
- Preserve independent helper package versions while recording exact provenance and a candidate-level SPDX SBOM.
- Separate read-only normal validation from narrowly permissioned candidate, signing, drafting, approval, and publication workflows.
- Make credential, capability, and owner-assignment gates explicit in the release handoff.
- Define `N` and `N-1` as explicit Current and Previous Supported Release Lines before implementation changes compatibility behavior.

**Non-Goals:**

- Bump the current Orchard product version.
- Create or rewrite tags, GitHub Releases, packages, apps, DMGs, checksums, manifests, SBOMs, or release notes.
- Implement build scripts, CI workflows, signing, notarization, or publication.
- Change app lifecycle, PKG lifecycle, generic artifact secrecy, or existing signing-order requirements.
- Force internal Python package versions to match the Orchard product version.
- Backfill a GitHub Release for `v0.4.0` or rewrite historical release evidence.
- Store credentials, keychain names, DSNs, local paths, or workflow session identifiers in release metadata.
- Assume that a private-repository GitHub feature or an Amore capability exists before a live implementation check proves it.

## Decisions

### Decision: A Root VERSION File Is Canonical Storage

Orchard will store its product version in a root `VERSION` file containing exactly one ASCII SemVer line and one terminal newline.
The file will contain no comments, surrounding whitespace, or SemVer build metadata.
Root and child Mix projects, runtime reporting, shell packaging, Swift app assembly, PKG metadata, filenames, and tag validation will derive from that file or fail exact validation against it.
Independent Python helper versions remain separate.

The `VERSION` file is canonical storage, while semantic authority remains `SPEC.md`, accepted release policy, and authorized transition evidence.
The alternative of retaining root Mix metadata as the cross-language authority is rejected because shell and Swift consumers should not require Mix evaluation or five synchronized literals.

### Decision: Product Version And Build Provenance Remain Separate

The Product Version identifies an Orchard development version, Release Candidate, or final release.
Build Provenance identifies a particular build through the full source commit, build date, Release Channel, Apple build number, toolchain, signing evidence, artifact digests, and helper provenance.
Ordinary commits and merges do not change Product Version.
SemVer build metadata is forbidden in `VERSION` because Orchard records build identity through governed provenance instead.

The alternative of bumping Product Version for every merge is rejected because Git and build evidence already provide immutable per-build identity.

### Decision: Pre-1.0 Transitions Use A Restricted Grammar

Development versions use `0.Y.Z-dev`, Release Candidates use `0.Y.Z-rc.K`, and final releases use `0.Y.Z`.
The candidate counter `K` starts at `1`, increases consecutively for the same base version, and has no leading zeroes.
At least one Verified Candidate is required before a final release.
A patch follows the complete `0.Y.(Z+1)-dev`, `0.Y.(Z+1)-rc.1`, and `0.Y.(Z+1)` sequence.
After a final release, a separate authorized transition selects the next patch or minor development line.
Skipped minor lines require explicit transition intent.
A transition to `1.0.0-dev` requires a separate apex compatibility decision.
Versions and tags never move backward and are never reused.

Additional commits after an RC transition retain that RC product version until an authorized transition selects the next candidate.
Only a signed tag identifies a governed candidate.
The first recommended governed transition is `0.5.0-dev` to `0.5.0-rc.1`, but this proposal does not perform that transition.

### Decision: Transition Authorization Is Bound To Reviewed Evidence

Every Product Version change will occur in a dedicated transition pull request that adds one append-only JSON record under `release/version-transitions/<target-version>.json`.
The record will identify its schema version, from and to versions, transition kind, authorization pull request, reason, Current Release Line, Previous Supported Release Line, fixed Release Channel, and Apple build-number allocation reference when an app is included.
Validation will require exact agreement between the record and version diff, an allowed transition, an unused target version, one fixed channel, and the required compatibility declaration.

A submitter-authored `approved_by` string is not authorization.
The preferred authorization proof is approval after the latest push from an approved Release Owner identity or group, verified read-only against the exact reviewed head revision.
If private-repository review protection is unavailable, a canonical detached approval envelope must bind the transition-record digest, exact head commit, target version, signer key identifier, issued time, expiry, nonce, and single-use purpose.
The fallback envelope must use deterministic canonical serialization, a detached signature verified against a versioned repository key registry, and revocation data checked at validation time.
The signed envelope must reside in a proved append-only evidence store outside the approved head commit, and the chosen store remains an implementation capability gate.
Validation must resolve the signer against a key-registry revision already trusted before the transition pull request began.
A transition pull request cannot change the trust roots used to authorize itself, and key additions, removals, or revocations require a separate protected trust-administration change approved under the previously trusted registry.
Publication remains disabled until one of those mechanisms is configured and proved.

### Decision: Signed Immutable Tags Start Candidate Construction

Governed tags are annotated and cryptographically signed by an authorized release actor.
RC tags use `v0.Y.Z-rc.K`, and final tags use `v0.Y.Z`.
Development tags, unsigned tags, invalid counters, moved tags, deleted tags, and reused tag names are rejected.
The tag is created only after the transition pull request merges and required validation passes for the exact committed version.
The tag starts candidate construction but does not prove that artifacts, a draft, or a Published Release exist.
Candidate identity is the exact signed tag, full source commit, and one Release Channel declared by the transition record.
One tag produces at most one Candidate Manifest for that fixed channel, and advancing from trial to pilot or from pilot to release requires a new Product Version and tag.

Infrastructure failures before manifest sealing may rebuild from the same exact tag and must record abandoned attempts.
After sealing, retries may only reuse preserved exact bytes.
Any digest change after sealing makes the candidate invalid and requires a new Product Version and tag.
A valid unpublished RC may be superseded by `rc.K+1`.
A Published Release is never superseded, but it may be withdrawn and followed by a patch or later release.

### Decision: Candidate And Distribution States Are Separate

Candidate states are `tagged`, `verified`, `invalid`, and `superseded`.
Distribution states are recorded independently per Release Channel as `not_started`, `staged`, `approved`, `partially_delivered`, `delivered`, `partially_published`, `published`, and `withdrawn`.
Draft is a GitHub-specific or Amore-specific surface state and is not a candidate state.
Failed is an attempt outcome and is not a durable candidate state.

GitHub surface states are `absent`, `draft`, `non_draft`, and `withdrawn`.
Amore surface states are `absent`, `staged`, `restricted_live`, `general_live`, and `withdrawn`.
Internal recipient-delivery states are `absent`, `staged`, `delivered`, and `withdrawn`.
Internal allows only recipient delivery through `absent -> staged -> delivered -> withdrawn`.
Trial allows GitHub `absent -> draft -> withdrawn` and Amore `absent -> staged -> restricted_live -> withdrawn`, and it prohibits a trial GitHub draft from becoming non-draft.
Pilot allows GitHub `absent -> draft -> non_draft -> withdrawn` and Amore `absent -> staged -> restricted_live -> withdrawn`.
Release allows GitHub `absent -> draft -> non_draft -> withdrawn` and Amore `absent -> staged -> general_live -> withdrawn`.
Failed attempts and unavailable observations produce signed attestations without advancing surface state.
Each transition requires the actor authorized for that surface and an atomic compare-and-swap append against the unique current attestation-chain head, so stale or concurrent forks fail closed.
Transitions to internal `delivered`, Amore `restricted_live` or `general_live`, and GitHub `non_draft` require a Verified Candidate or sealed Internal Build Manifest plus every digest-bound approval required by the channel.
GitHub `draft` and Amore `staged` may exist before approval, but they remain staging evidence and cannot yield successful or partial delivery or publication state until the required verification and approval are valid.
An externally observed live target state without those prerequisites records a fail-closed observation and does not advance the governed surface or distribution state.

Distribution state uses one ordered total reduction over every reachable combination.
Any required withdrawn surface or explicit channel withdrawal reduces first to `withdrawn`.
An invalid or superseded Candidate reduces to `withdrawn` when any required surface advanced beyond `absent` and otherwise reduces to `not_started`.
Before any complete or partial delivery or publication reduction, the Candidate must be `verified` or the Internal Build Manifest must be sealed and every channel-required approval must remain valid.
If those prerequisites are absent, pre-live `draft` or `staged` surfaces reduce only to `staged`, while any observed live target state fails closed without changing the governed state.
Internal reduces to `delivered` when its recipient surface is `delivered`.
Trial reduces to `delivered` only for GitHub `draft` plus Amore `restricted_live`.
Pilot reduces to `published` only for GitHub `non_draft` plus Amore `restricted_live`.
Release reduces to `published` only for GitHub `non_draft` plus Amore `general_live`.
Trial reduces to `partially_delivered` when exactly one required surface has reached its channel target, while pilot and release reduce to `partially_published` under the same target-state rule.
Any remaining verified combination with valid digest-bound approval reduces to `approved`.
Any remaining verified combination with at least one required surface in `draft` or `staged` reduces to `staged`.
All remaining combinations in which required surfaces are `absent` reduce to `not_started`.
Any combination outside the channel-specific transition graph or this ordered reduction fails closed without changing state.
Matching partial uploads are retryable, while mismatched bytes invalidate the candidate.
Operational rollback may restore an older verified release as the recommended download without moving tags, overwriting Release objects, or erasing publication evidence.

### Decision: Release Channels Are Complete Distribution Contracts

A Release Channel defines its eligible version form, audience, required artifacts, signing and verification level, publication surfaces, and completion condition.
Every Candidate has exactly one fixed Release Channel, and its compiled build-channel value must exactly match that channel.
Exact-byte Promotion occurs only within that channel, while a channel change requires a new Product Version and tag.

| Channel | Audience | Eligible version | Required distribution | Required surfaces and completion |
| --- | --- | --- | --- | --- |
| `internal` | Orchard collaborators | Development, RC, or final | Selected installable artifact, checksum, build manifest, validation summary, and component inventory, plus all apex-required sidecars for any DMG | No GitHub Release or Amore publication is required, and completion is Delivered when exact intended recipients can retrieve the recorded bytes. |
| `trial` | One named time-bounded evaluator engagement | RC | Signed and notarized DMG, release notes, DMG checksum, before and after signing manifests, Candidate Manifest, compatibility report, SPDX SBOM, and state evidence | A private GitHub draft record and an access-restricted Amore delivery surface must contain the same candidate, and successful completion is Delivered rather than Published. |
| `pilot` | Named design partners or a controlled production-like rollout | RC | The same required set as `trial` | A non-draft private GitHub Release and access-restricted Amore delivery must contain the exact approved bytes. |
| `release` | Generally available Orchard customers | Final | Signed and notarized DMG, release notes, DMG checksum, before and after signing manifests, Candidate Manifest, compatibility report, SPDX SBOM, and state evidence | General Amore delivery must be live and the private GitHub Release must be non-draft for the same approved candidate. |

PKG remains optional for every channel unless a later accepted offline-distribution contract makes it required.
Any included PKG must be signed, notarized, checksummed, and bound to the same Candidate Manifest.
Because this repository is private, GitHub Releases act as the internal release registry while Amore remains the customer-facing distribution surface assigned by `SPEC.md`.
The release workflow publishes through Amore first, verifies its live state and digest, and publishes the GitHub Release last.

Trial, pilot, and release publication remain disabled until Amore proves the required audience restriction, idempotency, digest inspection, and promotion behavior.
If Amore cannot distinguish restricted and general audiences, the affected channels remain disabled until an alternative surface is approved.

An untagged development build in the internal channel is an Internal Build rather than a Candidate.
It uses a commit-bound Internal Build Manifest with Product Version, full source commit, channel, artifact identities, validation summary, component inventory, and any Apple build-number allocation, and it does not enter Candidate or Candidate Manifest state.
Internal Build delivery produces signed, hash-chained Internal Build Attestations that reference the Internal Build Manifest digest and use the same proved append-only evidence store and signer-verification rules as Candidate State Attestations.
Signed RC or final internal builds use the Candidate path and one fixed internal channel.

### Decision: Final Verified Bytes Are Promoted Without Rebuild

Signing, notarization, stapling, mounted verification, final checksums, and required compatibility verification occur before an artifact becomes promotable.
The immutable Candidate Manifest records the identity of each final promotable artifact.
Drafting, uploading, approving, and publishing reuse those exact bytes and do not rebuild, resign, repackage, or inject metadata into them.
Any digest change creates a new candidate and repeats required verification.

### Decision: One Candidate Manifest Governs Cross-Artifact Agreement

Each Verified Candidate produces one immutable, versioned, canonically serialized Candidate Manifest after final artifact verification.
The manifest records Product Version, signed tag, full 40-character commit, Release Channel, transition-record digest, Current and Previous Supported Release Lines, Apple versions, required artifact matrix, signing and notarization results, helper provenance, SBOM digest, validation-result digests, and identity evidence for every governed artifact.
The manifest excludes itself from its artifact collection and receives its own SHA-256 after serialization.

Final distributable files record a path-independent logical name, byte size, media or artifact type, and SHA-256 over exact bytes.
Directory trees record a canonical JSON tree sorted by bytewise relative path with entry type, normalized permission mode, regular-file size and digest, and exact symlink target.
Tree identity excludes timestamps, user IDs, group IDs, and machine-local paths.
The Orchard app tree includes every file, including resources, `Info.plist`, signatures, and `CodeResources`.
Signing manifests remain required evidence but do not replace complete tree identity.

Later approval, attempt, upload, surface-observation, withdrawal, and publication events produce authenticated append-only State Attestations that reference the Candidate Manifest digest.
Each attestation uses deterministic canonical serialization, identifies the actor and signer key, records transition type, timestamp, channel, stable surface identifiers, and previous-attestation digest, and carries a detached signature verified against the versioned release key registry.
The chain is mandatory after the first attestation and resides in a proved append-only evidence store that rejects overwrite and deletion.
They never contain credentials, secrets, keychain names, local paths, or workflow session identifiers.
A replaceable current-state projection may be generated for convenience but is not audit evidence.

GitHub artifact attestations may supplement this evidence only after availability is proved.
The Candidate Manifest, SBOM, digests, and State Attestations remain sufficient when the GitHub feature is unavailable.

### Decision: Apple Metadata Uses A Numeric Base And Global Sequence

`CFBundleShortVersionString` uses the numeric `X.Y.Z` base of Product Version.
Prerelease identity remains in Product Version, tag, Release Channel, and Candidate Manifest.
`CFBundleVersion` uses one positive decimal integer in the safe range `1..9999` allocated by the protected Apple Build Number Allocator in an append-only allocation record.
The number increases globally for bundle identifier `com.orchard.app` across every channel, marketing version, hotfix, major-version transition, and distributed Internal Build.
A retry of the same exact Candidate or Internal Build reuses its allocated number, while a new tagged candidate or distributed app build consumes a new number.
Git SHA, date, workflow identity, and rerun count are not Apple build numbers.

Before initializing the sequence, implementation must inspect any historically distributed `com.orchard.app` build and seed above the highest observed value.
Allocation uses merge-time serialization and uniqueness checks, and app publication stops before `9999` is exhausted until an accepted migration defines and validates a replacement Apple-safe mapping.
Publication remains disabled until the historical maximum and live Amore and Apple validation paths are proved.

### Decision: Internal Helpers Keep Independent Versions And Exact Provenance

The tokenizer and MLX worker retain independent package versions.
For each helper, the Candidate Manifest records package name, package version, source commit, source-tree digest, `pyproject.toml` digest, `uv.lock` digest, selected extras, target platform and architecture, installed distribution inventory, and packaged tree or deterministic archive digest.
Numeric equality with Product Version neither establishes nor is required for compatibility.

Every tagged Candidate, including the internal channel, includes one SPDX 2.3 JSON SBOM covering first-party components, resolved Elixir dependencies, packaged Python dependencies, Swift package dependencies, and discoverable packaged native libraries and runtimes.
The Candidate Manifest references the SBOM by SHA-256.
The SBOM supplements and does not replace exact artifact and tree identities.

### Decision: Normal And Release CI Are Separate Trust Boundaries

Normal pull-request and `main` CI validates Product Version authority, transition rules, first-party BEAM agreement, packaging mappings, glossary and OpenSpec consistency, and affected tests with read-only repository permissions.
Candidate validation reads source and validation evidence but has no release credentials.
Candidate construction may write only ephemeral workflow artifacts.
Apple build-number allocation, Apple signing and notarization, GitHub drafting, Amore staging, publication approval, Amore publication, and GitHub publication use separate jobs and narrowly scoped credentials.
Signing, Amore publication, and GitHub publication credentials do not coexist in one job.

Distribution approval binds the Candidate Manifest or Internal Build Manifest digest, channel, Product Version, tag when applicable, required artifact set, approving identity, timestamp, expiry, and single-use intent.
Any changed digest, channel, artifact requirement, or compatibility declaration revokes approval automatically.
The GitHub Release becomes non-draft only after Amore live verification succeeds for the exact approved candidate.

Implementation must prove private-repository support for environment reviewers, self-review prevention, tag or ruleset restrictions, immutable Releases, environment-scoped secrets, and artifact attestations before claiming those controls.
If protected reviewer support is unavailable, the signed approval fallback and a separately controlled runner or secret store are required.
Trial delivery and pilot or release publication must not silently degrade to an unrestricted manual workflow.

### Decision: N And N-1 Use Explicit Release Lines

The Current Release Line is the candidate controller's Orchard `major.minor` line.
The Previous Supported Release Line is one explicitly enumerated earlier line and is not calculated by subtracting one from the minor version.
Patch and prerelease components do not create new Release Lines.
The terminology replaces ambiguous arithmetic while fulfilling the existing `SPEC.md` `N` and `N-1` guarantee.

The first governed `0.5` release selects `0.4` as its Previous Supported Release Line because `v0.4.0` is the only historical release tag.
Historical tagging does not prove compatibility, so every candidate must pass Current and Previous Supported Release Line suites.
A future `0.7` release may select `0.5` if `0.6` was never approved, and a future `1.0` release may select an explicitly approved `0.x` line.
The bundled worker must match the Node Agent Product Version required by `SPEC.md`, while its Python package version remains independent provenance.
Any candidate that cannot satisfy both required lines remains blocked unless an accepted change amends `SPEC.md` before release.

Current numeric minor arithmetic in `Orchard.Upgrade` remains unchanged until `SPEC.md` adopts this mapping and the implementation is reconciled in the same change.

## Risks / Trade-offs

- A root `VERSION` file can become another manually edited value if consumers do not derive from it, so derivation is required where practical and exact validation remains mandatory everywhere else.
- A tag-triggered build can fail after a signed immutable tag exists, so failed attempts remain evidence and replacement candidates receive new versions and tags.
- Separating candidate, distribution, and surface states is more explicit than one state machine, but it prevents a GitHub draft or split publication from being misreported as candidate failure.
- Apple prerelease candidates share one marketing version, so the global build sequence, tag, and Candidate Manifest distinguish them.
- A global Apple sequence needs protected allocation and historical seeding, so app publication stays disabled until both are proved.
- Current dirty-build support can be mistaken for release eligibility, so dirty or ambiguous provenance remains ineligible for governed promotion.
- Cross-artifact checks can duplicate artifact-specific verification, so this capability governs shared identity and references existing app and packaging contracts.
- Release automation can expose credentials too broadly, so credential capabilities remain isolated and publication requires digest-bound approval.
- Private-repository GitHub features may be unavailable, so the contract specifies required guarantees and fail-closed fallbacks rather than assuming a plan entitlement.
- Amore may not expose all required audience and digest semantics, so trial, pilot, and release publication remain disabled until live capability checks pass.
- An explicit Previous Supported Release Line adds a registry decision, but it handles skipped minor lines without inventing compatibility through arithmetic.
- A Candidate Manifest can become incomplete as channels evolve, so its schema is versioned and unsupported mandatory fields fail closed.
- SPDX generation increases release evidence, but it provides a portable candidate-level inventory without coupling policy to optional GitHub attestations.

## Migration Plan

1. Amend `SPEC.md` with accepted Product Version, Release Channel, publication, and Release Line semantics without changing the current version.
2. Add root `VERSION`, transition-record and compatibility-registry schemas, and exact first-party BEAM validation.
3. Derive or validate PKG, staged payload, app, Apple metadata, runtime reporting, and filenames against the governed identity.
4. Define Candidate Manifest, canonical tree, State Attestation, component-provenance, and SPDX SBOM schemas without enabling publication.
5. Add normal CI governance checks with read-only permissions.
6. Add a non-publishing signed-tag candidate workflow and exercise it in an isolated repository or dry-run mode.
7. Probe private-repository GitHub controls, live Amore behavior, historical Apple build numbers, signing identities, and credential custody.
8. Add isolated credential-gated signing, notarization, stapling, final verification, and manifest sealing in that order.
9. Add private GitHub draft creation and Amore staging only after candidate evidence passes.
10. Enable digest-bound approval and exact-byte promotion only after the required capability and role-assignment gates pass.
11. Publish through Amore first and make the matching private GitHub Release non-draft last.
12. Reconcile `SPEC.md` compatibility language and `Orchard.Upgrade` behavior in the same implementation branch.
13. Leave `v0.4.0` and historical state unchanged unless a separate accepted migration requests a backfill.

Rollback before publication disables candidate or publication workflows while leaving normal validation intact.
A Published Release is never rewritten or replaced in place, so remediation withdraws it and uses a new version, tag, and release.

### Decision: The Current Operating Model Uses Solo-Owner Custodianship

The solo Repository Owner currently holds the Release Owner, Tag Signer, publication approver, Apple Build Number Allocator, Apple-signing custodian, Amore-publication custodian, GitHub-publication custodian, and release-trust administrator roles.
No collaborator or backup currently has enough established experience and trust to assume those authorities.
This is a deliberate current operating constraint rather than an implied two-person control claim.

Each trial, pilot, or release Candidate must carry a signed single-owner exception bound to the exact Candidate Manifest digest and channel.
The exception is a mandatory `single_owner_exception` State Attestation with deterministic canonical serialization.
Its payload records schema version, Candidate Manifest digest, Release Channel, consolidated roles, signer identity and key identifier, single-Candidate purpose, issue time, expiry, unique nonce, and acknowledgement of every mandatory compensating control.
Validation verifies its signature against the pre-existing release key registry and current revocation data, rejects malformed, future-issued, or expired validity windows, and stores it in the Candidate's append-only attestation chain.
Every exception-dependent transition revalidates issue time and expiry against the trusted transition time before accessing delivery or publication capability.
Revocation before terminal use requires a later signed revocation attestation and blocks delivery or publication.
The authorized delivered, published, withdrawn, invalidated, or superseded transition atomically consumes the exception through the attestation-chain compare-and-swap update, after which it cannot authorize another transition or Candidate.
Approval, signing, staging, and publication remain separate actions and jobs even when the same Repository Owner performs them.
Hardware-backed signing credentials, least-privilege capability isolation, pre-existing trust roots, exact-byte verification, and immutable evidence remain mandatory compensating controls.
The absence of an experienced backup is recorded as a resilience risk in every release handoff but does not independently block release under a valid candidate-bound exception.

Two-person control remains the preferred future operating model after at least one collaborator has demonstrated sufficient release experience and has been explicitly entrusted with a named role.
Delegation is not automatic, and any new custodian or backup requires a separately protected trust-administration change before receiving authority.

## Remaining Gates

- Verify private-repository GitHub plan support for each proposed protected control before trial delivery or pilot and release publication.
- Verify Amore audience restriction, idempotency, digest inspection, and exact-byte promotion behavior before trial delivery or pilot and release publication.
- Inspect the highest historically distributed `CFBundleVersion` for `com.orchard.app` before allocating the first governed number.
- Identify actual signing identities, credential stores, and release hosts without recording secret or machine-local values in durable policy.
- Select and prove the append-only evidence store used for approvals and attestations.
