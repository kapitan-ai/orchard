#!/usr/bin/env bash

set -euo pipefail

portable=false
conformance=false
macos=false
mlx=false
packaging=false

enable_all() {
  portable=true
  conformance=true
  macos=true
  mlx=true
  packaging=true
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue

  case "$path" in
    SPEC.md|AGENTS.md|mix.exs|mix.lock|mise.toml|Makefile|package.json|package-lock.json|config/*|rel/*|proto/*|openspec/*|.github/workflows/*|apps/orchard_shared/*)
      enable_all
      ;;
    docs/decisions/*|docs/architecture.md|docs/tooling.md|docs/process.md)
      enable_all
      ;;
    docs/*|*.md)
      ;;
    packaging/*|scripts/build-app.sh|scripts/build-dmg.sh|scripts/build-payload.sh|scripts/sign-app.sh|scripts/test-app-*|scripts/test-build-app.sh|scripts/test-build-dmg.sh|scripts/test-build-payload.sh|scripts/test-payload-*)
      macos=true
      packaging=true
      ;;
    native/orchard_worker_mlx/*)
      conformance=true
      macos=true
      mlx=true
      ;;
    native/orchard_tokenizer/*)
      portable=true
      conformance=true
      ;;
    apps/orchard_controller/*|apps/orchard_node_agent/*|apps/orchard_cli/*)
      portable=true
      conformance=true
      ;;
    scripts/ci/*|scripts/test-linux-portable-core.sh|scripts/test-provider-neutral-conformance.sh)
      enable_all
      ;;
    *)
      enable_all
      ;;
  esac
done

printf 'portable=%s\n' "$portable"
printf 'conformance=%s\n' "$conformance"
printf 'macos=%s\n' "$macos"
printf 'mlx=%s\n' "$mlx"
printf 'packaging=%s\n' "$packaging"
