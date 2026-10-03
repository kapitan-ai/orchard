#!/usr/bin/env bash

set -euo pipefail

# The pinned action exposes its step outcome, not its internal failure stage,
# HTTP status or observed retry count. Never parse its raw logs for those facts.
if [[ "$#" -ne 2 || "${1-}" != failure || ! "${2-}" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  printf 'Invalid mise bootstrap diagnostic input\n' >&2
  exit 64
fi

printf 'bootstrap.action_outcome=failure\n'
printf 'bootstrap.mise_version_requested=%s\n' "$2"
printf 'bootstrap.failure_boundary=mise-action\n'
printf 'bootstrap.failure_stage=unknown\n'
printf 'bootstrap.http_status=unknown\n'
printf 'bootstrap.retries_observed=unknown\n'
# Source-bound policy, not a claim that this failure reached the download loop.
# jdx/mise-action c2a87611a18de5b3828c5652fe268e992400cb5c src/index.ts.
printf 'bootstrap.download_retry_limit_configured=5\n'
printf 'bootstrap.download_retry_delay_ms_configured=2000\n'
