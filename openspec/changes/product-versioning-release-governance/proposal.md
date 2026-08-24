## Why

Orchard has traceable build metadata and strong packaging verification, but it has no single enforced product-version authority or governed release identity spanning source, tags, runtime reporting, macOS artifacts, and publication state.
Active development now needs release-boundary SemVer and immutable build provenance to become one fail-closed, collaborator-reviewable contract before the next release is prepared.

## What Changes

- Define one machine-readable Orchard product-version authority and require every first-party BEAM application to derive from it or pass an exact consistency check.
- Define pre-1.0 development, release-candidate, final, patch, and next-development transitions while preserving the rule that ordinary commits and merges do not bump the product version.
- Keep product version separate from Git commit, build date, build channel, Apple build number, signing evidence, and independently versioned internal components.
- Bind each governed release to an exact product version, signed immutable tag, clean tagged commit, release channel, compatibility declaration, immutable candidate manifest, and append-only state attestations.
- Define separate candidate, distribution, and publication-surface states plus GitHub Release draft and publication gates without granting release permissions to normal pull-request or `main` validation.
- Require verified artifacts from the exact tagged commit to be promoted without rebuilding or changing their recorded bytes.
- Require cross-artifact agreement across runtime reporting, staged payload, `Orchard.app`, DMG contents, release filenames, manifests, sidecars, and publication evidence.
- Define an Apple-safe mapping from Orchard release identity to `CFBundleShortVersionString` and a globally monotonic numeric `CFBundleVersion` for the Orchard app bundle identifier.
- Preserve independent Python helper package versions and record exact helper provenance plus a candidate-level SPDX SBOM without treating helper versions as Orchard product-version mismatches.
- Add separate normal-validation and tag-triggered release gates, including exact-commit evidence, credential boundaries, owner approval boundaries, and fail-closed publication behavior.
- Replace the undefined use of controller and node version `N` and `N-1` with an explicitly enumerated Current Release Line and Previous Supported Release Line rather than allowing current implementation arithmetic to become policy silently.
- Keep the current product version unchanged and create no tags, releases, or distribution artifacts in this change.

## Capabilities

### New Capabilities

- `product-release-governance`: Defines Orchard product-version authority, release transitions, release identity and state, tag and commit agreement, compatibility declarations, immutable artifact promotion, cross-artifact consistency, Apple bundle mapping, internal component provenance and SBOM evidence, CI gates, and release handoff evidence.

### Modified Capabilities

- None.
  Existing `app-distribution-lifecycle` and `packaging-deployment` requirements remain the owners of artifact-specific assembly, verification, lifecycle, and generic distribution behavior.

## Impact

- SPEC.md impact: this proposal would refine §13.1 to define Orchard product-release identity, version transitions, and the meaning of controller and node compatibility versions, and would add narrow §11 release-governance requirements for immutable promotion, cross-artifact agreement, Apple bundle mapping, release state, and handoff evidence.
- Build metadata impact: the umbrella and first-party Mix applications, runtime version reporting, `Orchard.BuildInfo`, and upgrade compatibility checks would consume or validate one governed product-release identity.
- Distribution impact: staged payload, app, DMG, manifests, filenames, and sidecars would gain cross-artifact identity checks without duplicating their existing signing or lifecycle contracts.
- CI impact: normal validation would gain non-publishing governance checks, while a separately permissioned tag-triggered lane would own candidate construction, credential-gated verification, draft creation, and approved publication.
- Release operations impact: tags and GitHub Release state would become distinct, verified states tied to the same clean commit and immutable artifact digests.
- Compatibility impact: the proposal maps `N` to the Current Release Line and maps `N-1` to one explicitly enumerated Previous Supported Release Line, so the current numeric subtraction behavior must remain unchanged until the corresponding `SPEC.md` amendment and implementation land together.
- Approved design direction: the owner accepted the RP plus primary-source recommendations for canonical storage, pre-1.0 transitions, transition authorization, signed tag sequencing, channel completion, Apple mapping, helper provenance, SBOM evidence, compatibility representation, and least-privilege release boundaries.
- Current ownership: the solo Repository Owner holds every release, signing, publication, allocation, and trust-administration role under a candidate-bound single-owner exception with logical action separation and immutable evidence.
- Remaining gates: private-repository GitHub feature availability, Amore audience and promotion capabilities, historical Apple build-number maximum, concrete credential custody, release hosts, and the append-only evidence store must be verified before trial delivery or pilot and release publication is enabled.
