## Why

The required Orchard workflow currently concentrates portable, provider-neutral, macOS host, MLX, application, and DMG validation in one Apple Silicon job.
That structure cannot prove the accepted Linux portability contract, and it makes Controller-only changes pay for unrelated platform lanes.

Issue #287 establishes the prerequisite compile boundary by removing Darwin native-helper compilation from the portable Orchard control-plane core.
This dependent change makes the accepted portability-validation contract executable in required CI.

## What Changes

- Add a required Linux lane for portable compilation, static analysis, tests, coverage, tokenizer validation, and the non-accelerator Worker Runtime environment.
- Add a Linux provider-neutral conformance lane over Worker Runtime, Runtime Endpoint, capability, host-lifecycle invariant, and scheduler contracts.
- Keep macOS host-native, MLX, Orchard.app, DMG, and credential-free signing evidence in separate applicable lanes.
- Add an executable changed-path classifier with matrix tests for dependency fan-out.
- Preserve the `Required Orchard validation gate` name while making it aggregate every applicable lane.
- Add deliberate aggregate-gate tests for failed required lanes, skipped required lanes, and incorrectly executed inapplicable lanes.

No `SPEC.md` change is required.
This change implements `SPEC.md` §§1.2 and 1.4 plus the accepted `portability-validation` and `platform-profiles` specifications.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `portability-validation`: Defines the executable dependency classifier, conditional required lanes, and aggregate gate behavior.

## Impact

- Portable and provider-neutral changes gain required Linux evidence.
- Controller-only portable changes can skip unrelated Apple-only lanes when the classifier proves that those dependencies are unaffected.
- Normative, shared-interface, root-toolchain, root-configuration, release-composition, and workflow changes fan out to all lanes.
- This change makes no Linux Platform Profile, distribution, host-lifecycle, Node, or accelerator support claim.
