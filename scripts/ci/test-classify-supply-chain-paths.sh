#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/ci/classify-supply-chain-paths.sh"

assert_case() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual

  actual="$(printf '%s\n' "$@" | "$CLASSIFIER")"
  if [[ "$actual" != "supply_chain=$expected" ]]; then
    printf 'supply-chain classification case failed: %s\nexpected: supply_chain=%s\nactual:   %s\n' \
      "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_rejects() {
  local name="$1"
  local input="$2"
  local status=0

  printf '%s' "$input" | "$CLASSIFIER" >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'supply-chain classification case failed: %s\nexpected a non-zero exit, got 0\n' \
      "$name" >&2
    exit 1
  fi
}

assert_case docs-only false docs/local-dev.md README.md
assert_case app-source false apps/orchard_cli/lib/orchard_cli/commands/status.ex
assert_case lookalike-lockfile-names false docs/mix.lock.md native/orchard_tokenizer/uv.lock.orig
assert_case root-mix-lock true mix.lock
assert_case umbrella-app-manifest true apps/orchard_controller/mix.exs
assert_case native-uv-lock true native/orchard_worker_mlx/uv.lock
assert_case nested-tooling-uv-lock true proto/orchard/worker/tooling/uv.lock
assert_case native-pyproject true native/orchard_tokenizer/pyproject.toml
assert_case root-npm-manifest true package.json
assert_case nested-npm-manifest true native/new_tool/package.json
assert_case root-npm-lock true package-lock.json
assert_case future-ecosystem-lock true native/new_tool/Cargo.lock
assert_case future-ecosystem-manifest true native/new_tool/Cargo.toml
assert_case swift-manifest true packaging/app/Package.swift
assert_case swift-lock true packaging/app/Package.resolved
assert_case workflow true .github/workflows/required-validation.yml
assert_case mise-pins true mise.toml
assert_case osv-exceptions true osv-scanner.toml
assert_case root-zizmor-config true zizmor.yml
assert_case root-zizmor-config-yaml true zizmor.yaml
assert_case makefile true Makefile
assert_case ci-scripts true scripts/ci/osv-scan.mjs
assert_case docs-plus-lockfile true README.md mix.lock
assert_case quoted-path true '"caf\303\251/uv.lock"'

assert_rejects empty-diff ''
assert_rejects blank-line-only-diff $'\n\n'

# Real `git diff --name-only` output, as the workflow feeds it: Git quotes a
# lockfile path with non-ASCII or special characters.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init --quiet
git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit --quiet --allow-empty -m base
mkdir -p "$fixture/café" "$fixture/tab	dir"
printf 'version = 1\n' > "$fixture/café/uv.lock"
printf 'version = 1\n' > "$fixture/tab	dir/mix.lock"
git -C "$fixture" add .
git -C "$fixture" -c user.name=t -c user.email=t@example.invalid commit --quiet -m lockfiles
actual="$(git -C "$fixture" diff --name-only --no-renames HEAD~1 HEAD | "$CLASSIFIER")"
if [[ "$actual" != "supply_chain=true" ]]; then
  printf 'supply-chain classification case failed: real-git-quoted-paths\nactual: %s\n' "$actual" >&2
  exit 1
fi

printf 'supply-chain path-classification tests passed\n'
