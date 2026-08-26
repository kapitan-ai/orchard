## Context

`OrchardCLI.SecretTTY` and `OrchardCLI.LifecycleNative` actively consume `orchard-secret-tty` and `orchard-lifecycle-helper` from the CLI application `priv` directory.
The helpers preserve terminal custody, process identity, bounded launchd interaction, and fail-closed lifecycle behavior.
Their source and compiler hook currently live inside `apps/orchard_cli`, so every ordinary umbrella compile owns a Darwin build whether or not the target operation needs macOS host behavior.

## Goals / Non-Goals

**Goals:**

- Make ordinary portable Orchard control-plane core compilation independent of Orchard Darwin helper compilation.
- Preserve retained macOS terminal-custody and lifecycle behavior.
- Use one explicit builder for source tests and packaged staging.
- Keep missing or invalid helpers fail closed.

**Non-Goals:**

- Change the terminal-custody protocol or lifecycle process-identity semantics.
- Restore Managed Node Agent handover.
- Move normal CLI command authority to Controller APIs.
- Define or support a Linux Distribution Profile.

## Decisions

### macOS packaging owns helper source and compilation

Darwin C sources SHALL live under `packaging/macos/native_helpers` and SHALL be compiled only through `scripts/build-macos-native-helpers.sh`.
The portable CLI Mix project SHALL NOT declare a native compiler hook for these sources.

Keeping the sources under `apps/orchard_cli` behind an operating-system conditional was rejected because the portable application would continue to own a platform compiler boundary.

### The selected CLI application priv directory remains the invocation seam

The explicit builder SHALL stage built helpers into an output directory selected by the macOS source-test or payload workflow.
Those workflows SHALL select the applicable `orchard_cli` application `priv` directory, preserving existing runtime discovery and fail-closed behavior.

Introducing a second packaged helper lookup root was rejected because it would broaden runtime configuration and signing behavior without improving dependency direction.
The host-artifact boundary is defined by source ownership and explicit build invocation, not by requiring a new runtime path.

### Portable and macOS proofs remain separate

A portable compilation regression SHALL place an `xcrun` tripwire around first-party umbrella compilation and reject any emitted Orchard Darwin helper.
Separate macOS tests SHALL build the helpers explicitly and exercise lifecycle and PTY behavior.
Payload tests SHALL prove both production helpers are staged and the test-only helper is excluded.

## Risks / Trade-offs

- **A caller forgets the explicit helper build** - retained helper operations fail closed, and documented Make targets plus CI build the helpers before macOS tests.
- **A stale helper remains in a local build tree** - the portable regression forces first-party recompilation in a fixed development environment and compares the Darwin helper artifact inventory before and after that compilation, rejecting any newly emitted or changed helper. It does not delete build output, so helpers already staged by an explicit builder invocation are preserved in every build environment and are not counted as emission.
- **Packaging omits a helper** - payload integration tests require both executable helpers in the packaged CLI release.

## Migration Plan

No persisted state or operator migration is required.
Source developers run the explicit macOS helper Make target when exercising retained host-native CLI behavior.
Payload assembly invokes the builder automatically because macOS native distribution owns those artifacts.

## Open Questions

None.
