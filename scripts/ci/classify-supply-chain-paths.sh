#!/usr/bin/env bash
#
# Reads changed paths on stdin and prints supply_chain=<true|false>. The
# supply-chain lane is required when a change can alter third-party
# dependencies, workflow definitions, or the scanners and their pins
# (docs/tooling.md, "Supply-Chain Checks").

set -euo pipefail

supply_chain=false
saw_path=false

while IFS= read -r path; do
  [[ -n "$path" ]] || continue

  saw_path=true

  case "$path" in
    .github/*|mise.toml|osv-scanner.toml|Makefile|package.json|scripts/ci/*)
      supply_chain=true
      ;;
  esac

  # Dependency manifests and the lockfile names in scripts/ci/osv-scan.mjs,
  # at any depth.
  case "${path##*/}" in
    mix.exs|pyproject.toml|Cargo.lock|Gemfile.lock|Pipfile.lock|bun.lock|composer.lock|go.mod|mix.lock|package-lock.json|pnpm-lock.yaml|poetry.lock|pylock.toml|uv.lock|yarn.lock)
      supply_chain=true
      ;;
  esac
done

if [[ "$saw_path" != "true" ]]; then
  printf 'classify-supply-chain-paths: no changed paths on stdin\n' >&2
  exit 1
fi

printf 'supply_chain=%s\n' "$supply_chain"
