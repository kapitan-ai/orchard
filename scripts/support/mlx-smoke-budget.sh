#!/usr/bin/env bash

mlx_smoke_sum_ms() {
  local total_ms=0
  local value

  for value in "$@"; do
    case "$value" in
      '' | *[!0-9]*)
        printf 'MLX smoke phase budgets must be non-negative integer milliseconds\n' >&2
        return 64
        ;;
    esac

    total_ms="$((10#$total_ms + 10#$value))"
  done

  printf '%s\n' "$total_ms"
}

mlx_smoke_exunit_timeout_ms() {
  if [ "$#" -ne 7 ]; then
    printf 'mlx_smoke_exunit_timeout_ms requires seven phase budgets\n' >&2
    return 64
  fi

  mlx_smoke_sum_ms "$@"
}

mlx_smoke_configure_budgets() {
  : "${MLX_SMOKE_SOURCE_HASH_TIMEOUT_MS:=60000}"
  : "${MLX_SMOKE_ACQUISITION_TIMEOUT_MS:=120000}"
  : "${MLX_SMOKE_WORKER_READY_TIMEOUT_MS:=30000}"
  : "${MLX_SMOKE_WORKER_LOAD_TIMEOUT_MS:=120000}"
  : "${MLX_SMOKE_RPC_HEADROOM_MS:=5000}"
  : "${MLX_SMOKE_INFERENCE_TIMEOUT_MS:=60000}"
  : "${MLX_SMOKE_CLEANUP_HEADROOM_MS:=60000}"

  MLX_SMOKE_EXUNIT_TIMEOUT_MS="$(
    mlx_smoke_exunit_timeout_ms \
      "$MLX_SMOKE_SOURCE_HASH_TIMEOUT_MS" \
      "$MLX_SMOKE_ACQUISITION_TIMEOUT_MS" \
      "$MLX_SMOKE_WORKER_READY_TIMEOUT_MS" \
      "$MLX_SMOKE_WORKER_LOAD_TIMEOUT_MS" \
      "$MLX_SMOKE_RPC_HEADROOM_MS" \
      "$MLX_SMOKE_INFERENCE_TIMEOUT_MS" \
      "$MLX_SMOKE_CLEANUP_HEADROOM_MS"
  )"

  MLX_SMOKE_ENSURE_LOADED_TIMEOUT_MS="$(
    mlx_smoke_sum_ms \
      "$MLX_SMOKE_ACQUISITION_TIMEOUT_MS" \
      "$MLX_SMOKE_WORKER_READY_TIMEOUT_MS" \
      "$MLX_SMOKE_WORKER_LOAD_TIMEOUT_MS"
  )"

  MLX_SMOKE_ENSURE_LOADED_RPC_TIMEOUT_MS="$((
    10#$MLX_SMOKE_ENSURE_LOADED_TIMEOUT_MS + 10#$MLX_SMOKE_RPC_HEADROOM_MS
  ))"

  export \
    MLX_SMOKE_SOURCE_HASH_TIMEOUT_MS \
    MLX_SMOKE_ACQUISITION_TIMEOUT_MS \
    MLX_SMOKE_WORKER_READY_TIMEOUT_MS \
    MLX_SMOKE_WORKER_LOAD_TIMEOUT_MS \
    MLX_SMOKE_RPC_HEADROOM_MS \
    MLX_SMOKE_INFERENCE_TIMEOUT_MS \
    MLX_SMOKE_CLEANUP_HEADROOM_MS \
    MLX_SMOKE_ENSURE_LOADED_TIMEOUT_MS \
    MLX_SMOKE_ENSURE_LOADED_RPC_TIMEOUT_MS \
    MLX_SMOKE_EXUNIT_TIMEOUT_MS
}
