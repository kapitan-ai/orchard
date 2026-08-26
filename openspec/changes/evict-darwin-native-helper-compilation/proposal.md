## Why

The portable `orchard_cli` application unconditionally invokes `elixir_make`, whose Makefile compiles two Darwin helpers with `xcrun clang`.
That makes ordinary portable Orchard control-plane core compilation depend on Apple tooling even though the helpers implement macOS host behavior.

## What Changes

- Remove Darwin helper compilation and `elixir_make` ownership from the portable CLI Mix project.
- Move the retained terminal-custody and lifecycle helper sources under an explicit macOS host-artifact boundary.
- Add one explicit builder for source development, macOS tests, payload assembly, and packaged CLI staging.
- Preserve the existing CLI application `priv` lookup contract for built helpers while keeping helper absence fail closed.
- Add regression proofs that portable compilation invokes no Orchard Darwin helper build and emits no Orchard Darwin helper artifact.

No `SPEC.md` behavior change is required.
This change implements the dependency direction already defined by `SPEC.md` §§1.2, 1.4, 2.5, 11.4, and 14.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-lifecycle-adapters`: Defines the explicit macOS native-helper ownership, build, staging, and discovery boundary.

## Impact

- Portable `orchard_cli` and root umbrella compilation no longer invoke Darwin helper compilation.
- macOS source development and tests explicitly build helpers into the selected CLI application `priv` directory.
- Payload assembly builds and stages the retained helpers before producing the packaged CLI release.
- No Linux support claim, lifecycle behavior change, CLI authority migration, or Managed Node Agent handover is introduced.
