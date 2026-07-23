## 1. Owner Decisions And Contract Approval

- [x] 1.1 Approve root `VERSION` as canonical storage, with every first-party Mix project and cross-language consumer deriving from it or failing exact validation.
- [x] 1.2 Approve the restricted pre-1.0 `-dev`, `-rc.K`, final, patch, and next-development grammar plus dedicated transition pull requests and digest-bound authorization evidence.
- [x] 1.3 Approve signed immutable tag grammar, one fixed channel per candidate, tag-before-build sequencing, separated candidate, delivery, distribution, and surface states, and exact-byte retry and withdrawal semantics.
- [x] 1.4 Approve the `internal`, `trial`, `pilot`, and `release` channel contracts, optional PKG treatment, and conjunctive GitHub plus Amore completion for pilot and release.
- [x] 1.5 Approve numeric-base `CFBundleShortVersionString` and one globally increasing `CFBundleVersion` allocation sequence in the safe range `1..9999` for `com.orchard.app`.
- [x] 1.6 Approve exact helper package, source, lockfile, installed-distribution, and packaged-tree provenance plus an SPDX 2.3 JSON SBOM for every tagged Candidate.
- [x] 1.7 Approve Current Release Line and explicitly enumerated Previous Supported Release Line as the meaning of `N` and `N-1`, with complete candidate compatibility suites.
- [x] 1.8 Approve separate least-privilege candidate, signing, drafting, staging, approval, and publication boundaries plus fail-closed fallbacks for unavailable private-repository GitHub features.
- [x] 1.9 Record the solo Repository Owner as the current holder of every release, signing, allocation, publication, and trust-administration role, with no experienced backup, and require a signed candidate-bound single-owner exception plus logical action separation for each trial, pilot, or release Candidate.
- [ ] 1.10 Verify private-repository GitHub protections, Amore audience and promotion behavior, historical `CFBundleVersion` maximum, signing identities, credential stores, and release hosts before trial delivery or pilot and release publication.

## 2. Apex Contract And Durable Documentation

- [ ] 2.1 Update `SPEC.md` §13.1 with the accepted product-version authority, transition grammar, tag identity, and product-release compatibility mapping without changing the current version.
- [ ] 2.2 Add narrow `SPEC.md` §11 requirements for governed release identity, immutable promotion, cross-artifact agreement, Apple mapping, publication state, and handoff evidence without duplicating artifact-specific contracts.
- [ ] 2.3 Add or update a decision record only if the accepted authority, compatibility, or publication design meets Orchard's durable ADR criteria.
- [ ] 2.4 Update `docs/process.md`, `docs/tooling.md`, contributor guidance, and relevant packaging documentation with the accepted release workflow and exact validation commands.
- [ ] 2.5 Reconcile any accepted spec change with `app-distribution-lifecycle` and `packaging-deployment` references without adding adjacent deltas unless their existing requirements actually change.

## 3. Product-Version Authority And Normal Validation

- [ ] 3.1 Introduce root `VERSION` with the current Product Version and the exact file grammar without changing its value.
- [ ] 3.2 Derive or validate the umbrella and all first-party Mix application versions against the canonical authority.
- [ ] 3.3 Derive or validate runtime version reporting, controller membership evidence, node-agent advertisement, and CLI fallback reporting against the canonical authority.
- [ ] 3.4 Add a repository command that validates Product Version grammar, dedicated transition evidence, canonical detached approvals, one-channel signed-tag rules, first-party agreement, compatibility declarations, Apple allocation, and packaging mappings without mutating files.
- [ ] 3.5 Add public-interface regression tests that fail on root, child Mix, runtime, PKG, or app product-version drift.
- [ ] 3.6 Add the non-publishing governance command to pull-request and `main` CI while retaining read-only release permissions.

## 4. Release Manifest And Cross-Artifact Consistency

- [ ] 4.1 Define and test the immutable Candidate Manifest, Internal Build Manifest, canonical detached approval, deterministic `single_owner_exception` and revocation attestations with atomic terminal consumption, mandatory signed Candidate and Internal Build Attestation chains with atomic compare-and-swap heads, pre-existing-trust key-registry rules, surface transition and reduction rules, separate candidate and delivery or publication states, required artifacts, signing and notarization evidence, compatibility declaration, component provenance, SPDX SBOM reference, and explicit exclusion of manifest self-digests.
- [ ] 4.2 Record exact Python helper package, source, source-tree, `pyproject.toml`, `uv.lock`, extras, target, installed-distribution, and packaged-tree provenance without changing helper package versions to match Orchard.
- [ ] 4.3 Make PKG metadata, staged payload metadata, runtime release contents, filenames, Git commit, build date, and build channel derive from or validate against the governed identity.
- [ ] 4.4 Make app assembly derive or validate numeric-base `CFBundleShortVersionString`, the globally allocated `1..9999` numeric `CFBundleVersion`, Product Version, full source commit, fixed channel, and staged payload identity.
- [ ] 4.5 Define exact file identity and canonical JSON tree identity, then inspect mounted DMG contents, PKG metadata, staged payloads, OTP releases, complete app bundles, manifests, SBOMs, and sidecars against the Candidate Manifest.
- [ ] 4.6 Add immutable-promotion checks that reject dirty provenance, missing final verification, or any digest change after signing, notarization, stapling, mounted verification, and checksum generation.
- [ ] 4.7 Add test fixtures for intentionally absent optional artifacts and missing required channel artifacts without requiring app and PKG to ship together unless the approved channel policy says so.

## 5. Tag Candidate And Publication Workflows

- [ ] 5.1 Add an untagged commit-bound Internal Build workflow that constructs the approved artifact set, allocates an Apple build number when an app is distributed, seals an Internal Build Manifest, records signed chained delivery attestations, and reduces recipient-delivery state without entering Candidate state.
- [ ] 5.2 Add a non-publishing tag-triggered candidate lane that validates signed annotated tag grammar, exact committed-version agreement, isolated clean source, one fixed channel, compatibility declaration, and required validation results.
- [ ] 5.3 Construct each approved unsigned or staged candidate input once from the exact tagged commit without finalizing the Candidate Manifest.
- [ ] 5.4 Isolate and run signing, notarization, stapling, and credential access behind protected environments with least-privilege permissions and explicit failure reporting.
- [ ] 5.5 Perform final artifact and mounted verification, generate final checksums, and then generate the immutable Candidate Manifest from the final promotable bytes and canonical tree identities.
- [ ] 5.6 Create or update a private draft GitHub Release only after candidate identity, final artifact, Candidate Manifest, SBOM, and credential-gated verification succeed, and record the surface transition in an append-only State Attestation.
- [ ] 5.7 Require digest-bound Release Owner approval, a valid candidate-bound single-owner exception or future approved role separation, proved capabilities, and complete handoff evidence before trial delivery or promotion of exact staged bytes through Amore and before making a GitHub Release non-draft.
- [ ] 5.8 Verify every staged, uploaded, delivered, and published asset against the sealed identity, preserve matching partial uploads, record split trial delivery as `partially_delivered`, record split pilot or release surfaces as `partially_published`, publish through Amore first and GitHub last, and require a new version and tag for channel or sealed-byte changes.
- [ ] 5.9 Add failure-path tests for tag mismatch, unsigned or moved tags, dirty provenance, channel changes, missing artifacts, invalid or exhausted Apple versions, digest drift, unavailable credentials, forged, stale, revoked, malformed, future-issued, expired, replayed, concurrently consumed, or denied approval, Single-owner Exceptions, and attestations, unauthorized observed live surfaces, pre-approval staging, partial delivery or publication, invalid candidates, supersession, withdrawal, concurrent attestation forks, and unavailable platform capabilities.

## 6. Controller And Node Compatibility

- [ ] 6.1 Add Current Release Line and explicitly enumerated Previous Supported Release Line to the Candidate Manifest and reject declarations that are absent, contradictory, narrower than the apex guarantee, or unsupported.
- [ ] 6.2 Update `Orchard.Upgrade` and its public-interface tests in the same branch as the corresponding `SPEC.md` amendment so compatibility follows explicit Release Lines rather than minor-version subtraction.
- [ ] 6.3 Add controller and Node Agent compatibility tests across current-line patch and prerelease versions, the explicitly named Previous Supported Release Line, skipped minors, undeclared lines, and older lines.
- [ ] 6.4 Verify that the bundled worker matches the required Orchard node-agent release identity while its Python package version remains independent provenance.

## 7. Validation And Handoff

- [ ] 7.1 Run focused unit and integration tests for version authority, runtime reporting, packaging mappings, candidate-manifest and state-attestation validation, tag gates, and compatibility behavior.
- [ ] 7.2 Run the full Elixir workflow from `AGENTS.md`, including formatting, warnings-as-errors compilation, Credo, Dialyzer, tests, and coverage.
- [ ] 7.3 Run both native package Ruff, test, and coverage workflows, verify exact helper provenance and SPDX SBOM generation, and leave independent package versions unchanged unless separately justified.
- [ ] 7.4 Run the Swift, app lifecycle, app assembly, signing-contract, DMG, PKG, and relevant credential-free release workflow tests from `AGENTS.md`.
- [ ] 7.5 Run `git diff --check` and strictly validate `product-versioning-release-governance` with telemetry disabled.
- [ ] 7.6 Run RP Review and No Mistakes against the accepted contract, implementation diff, tests, release failure paths, and exact validation evidence until blocker and important findings are resolved.
- [ ] 7.7 Record a conditional release-governance handoff with common Product Version, full commit, Release Channel, distribution and surface state, artifact identities, validation results, capability gates, role assignments, and residual risks; include signed tag, transition record, Release Lines, Candidate Manifest, Candidate State Attestations, and SBOM for a tagged Candidate, or Internal Build Manifest and Internal Build Attestations with Candidate-only fields marked not applicable for an untagged Internal Build.
- [ ] 7.8 After archive or sync, validate all OpenSpec materials strictly and review generated main specs for incomplete prose such as `Purpose TBD`.
