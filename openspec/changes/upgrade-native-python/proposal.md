# Upgrade the native Python toolchain

## Why

CPython gh-155752 has no Python 3.11 backport. Python 3.14.10 includes the fix
and provides a longer maintenance window than the security-only 3.13 line.
Template sandbox hardening is complementary mitigation, not a replacement for
the interpreter fix.

## What Changes

- Select Python 3.14.10 through mise and uv for native development and CI.
- Align active native Ruff targets and toolchain fixtures with that interpreter.
- Verify the tokenizer, MLX worker, and proto-tooling locks on the new pin
  without unrelated dependency upgrades.

## Impact

No SPEC.md change is proposed. SPEC §3.5 rendering, §7.2.9 exact-tuple evidence,
and §11.0 distribution pause remain unchanged. Runtime dependency changes
trigger requalification under docs/model-qualification.md; existing records
and support claims are not approved or modified by this change.

The migration must complete by December 31, 2026, and before the SPEC §11.0
distribution pause lifts. Python 3.13.18 is a contingency only
after a failed Apple Silicon MLX check on 3.14 is reported to the owner.
