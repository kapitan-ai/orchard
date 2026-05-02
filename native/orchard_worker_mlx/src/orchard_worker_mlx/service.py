from __future__ import annotations

import json
import logging
import math
import signal
import threading
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from types import FrameType
from typing import Any, Literal

import grpc

from orchard_worker_mlx.backends import (
    Backend,
    BackendError,
    build_backend,
    valid_cache_affinity_fingerprint,
)
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, events_pb2, runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import (
    worker_runtime_pb2,
    worker_runtime_pb2_grpc,
)

logger = logging.getLogger(__name__)

# Default TTL for cancel tombstones (seconds).
_DEFAULT_CANCEL_TOMBSTONE_TTL_S = 60.0
_DEFAULT_GRPC_WORKER_HEADROOM = 2
_DEFAULT_GRPC_WORKERS_MIN = 4
_UINT32_MAX = 4_294_967_295
_UINT64_MAX = 18_446_744_073_709_551_615
_MEMORY_BUDGET_UINT64_FIELDS = (
    "max_recommended_working_set_size_bytes",
    "target_working_set_bytes",
    "overhead_bytes",
    "resident_memory_bytes",
    "estimated_headroom_bytes",
    "kv_cache_bytes_per_token",
    "prefill_workspace_bytes_per_token",
)
_MEMORY_BUDGET_FLOAT_FIELDS = ("utilization",)
_INVALID_MEMORY_BUDGET_NUMERIC_MESSAGE = "memory budget status contained invalid numeric fields"
_PREFIX_CACHE_UINT32_FIELDS = ("entry_count", "configured_max_entries")
_PREFIX_CACHE_UINT64_FIELDS = (
    "total_bytes",
    "hits",
    "misses",
    "failures",
    "stores",
    "evictions",
    "configured_max_bytes",
    "session_started_unix_ms",
)
_PREFIX_CACHE_STATUS_CODES = frozenset({"ok", "disabled", "unavailable", "invalid_status", "error"})
_INVALID_PREFIX_CACHE_MESSAGE = "backend prefix cache status was invalid"
_MAX_PREFIX_CACHE_FINGERPRINTS = 64
_SCORE_PREFIX_CACHE_STATUS_CODES = frozenset(
    {
        "ok",
        "disabled",
        "unavailable",
        "model_not_loaded",
        "timeout",
        "invalid_request",
        "error",
        "unsupported_version",
    }
)
_SCORE_PREFIX_CACHE_TIERS = frozenset(
    {"resident_fingerprint", "recent_fingerprint_only", "no_match", "unknown"}
)
_SAFE_SCORE_PREFIX_CACHE_ERROR_MESSAGE = "score prefix cache unavailable"


@dataclass(slots=True)
class CancelEntry:
    """Tracks a cancellation signal for a request.

    ``phase`` distinguishes pre-Generate tombstones from active generations.
    Tombstones have an ``expires_at_monotonic`` after which they are pruned.
    """

    event: threading.Event
    phase: Literal["tombstone", "active"] = "tombstone"
    expires_at_monotonic: float | None = None


def _status_bool(value: Any) -> bool:
    return value is True


def _valid_status_uint32(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= _UINT32_MAX


def _status_uint32(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        return 0
    if value < 0:
        return 0
    return min(value, _UINT32_MAX)


def _valid_status_uint64(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= _UINT64_MAX


def _status_uint64(value: Any) -> int:
    if _valid_status_uint64(value):
        return value
    return 0


def _valid_status_float(value: Any) -> bool:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            converted = float(value)
        except (OverflowError, ValueError):
            return False

        return math.isfinite(converted) and converted >= 0.0

    return False


def _status_float(value: Any) -> float:
    if _valid_status_float(value):
        return float(value)
    return 0.0


def _status_string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _memory_budget_claims_usable(memory_budget: dict[str, Any]) -> bool:
    return (
        _status_string(memory_budget.get("status_code")) == "ok"
        or _status_bool(memory_budget.get("budget_available"))
        or _status_bool(memory_budget.get("headroom_available"))
    )


def _invalid_memory_budget_numeric_fields(memory_budget: dict[str, Any]) -> list[str]:
    claims_usable = _memory_budget_claims_usable(memory_budget)
    invalid_fields: list[str] = []

    for field in _MEMORY_BUDGET_UINT64_FIELDS:
        if field not in memory_budget:
            if claims_usable:
                invalid_fields.append(field)
            continue

        if not _valid_status_uint64(memory_budget[field]):
            invalid_fields.append(field)

    for field in _MEMORY_BUDGET_FLOAT_FIELDS:
        if field not in memory_budget:
            if claims_usable:
                invalid_fields.append(field)
            continue

        if not _valid_status_float(memory_budget[field]):
            invalid_fields.append(field)

    return invalid_fields


def _invalid_numeric_memory_budget_status_response(
    memory_budget: dict[str, Any],
) -> worker_runtime_pb2.WorkerMemoryBudgetStatus:
    return worker_runtime_pb2.WorkerMemoryBudgetStatus(
        mode="observe",
        budget_available=False,
        headroom_available=False,
        status_code="invalid_status",
        status_message=_INVALID_MEMORY_BUDGET_NUMERIC_MESSAGE,
        source=_status_string(memory_budget.get("source")),
    )


def _memory_budget_status_response(
    memory_budget: Any,
) -> worker_runtime_pb2.WorkerMemoryBudgetStatus | None:
    if memory_budget is None:
        return None

    if not isinstance(memory_budget, dict):
        return worker_runtime_pb2.WorkerMemoryBudgetStatus(
            mode="observe",
            budget_available=False,
            headroom_available=False,
            status_code="invalid_status",
            status_message="backend memory budget status was invalid",
        )

    if _invalid_memory_budget_numeric_fields(memory_budget):
        return _invalid_numeric_memory_budget_status_response(memory_budget)

    return worker_runtime_pb2.WorkerMemoryBudgetStatus(
        mode=_status_string(memory_budget.get("mode")),
        budget_available=_status_bool(memory_budget.get("budget_available")),
        headroom_available=_status_bool(memory_budget.get("headroom_available")),
        status_code=_status_string(memory_budget.get("status_code")),
        status_message=_status_string(memory_budget.get("status_message")),
        source=_status_string(memory_budget.get("source")),
        max_recommended_working_set_size_bytes=_status_uint64(
            memory_budget.get("max_recommended_working_set_size_bytes")
        ),
        utilization=_status_float(memory_budget.get("utilization")),
        target_working_set_bytes=_status_uint64(memory_budget.get("target_working_set_bytes")),
        overhead_bytes=_status_uint64(memory_budget.get("overhead_bytes")),
        resident_memory_bytes=_status_uint64(memory_budget.get("resident_memory_bytes")),
        estimated_headroom_bytes=_status_uint64(memory_budget.get("estimated_headroom_bytes")),
        kv_cache_bytes_per_token=_status_uint64(memory_budget.get("kv_cache_bytes_per_token")),
        prefill_workspace_bytes_per_token=_status_uint64(
            memory_budget.get("prefill_workspace_bytes_per_token")
        ),
    )


def _prefix_cache_disabled(prefix_cache_config: Any | None) -> bool:
    return _status_string(getattr(prefix_cache_config, "mode", "")) == "disabled"


def _prefix_cache_caps(prefix_cache_config: Any | None) -> tuple[int, int]:
    return (
        _status_uint32(getattr(prefix_cache_config, "max_entries", 0)),
        _status_uint64(getattr(prefix_cache_config, "max_bytes", 0)),
    )


def _error_prefix_cache_status_response(
    prefix_cache_config: Any | None,
    status_message: str,
) -> worker_runtime_pb2.WorkerPrefixCacheStatus:
    configured_max_entries, configured_max_bytes = _prefix_cache_caps(prefix_cache_config)
    return worker_runtime_pb2.WorkerPrefixCacheStatus(
        implementation="unknown",
        enabled=True,
        configured_max_entries=configured_max_entries,
        configured_max_bytes=configured_max_bytes,
        status_code="error",
        status_message=status_message,
    )


def _disabled_prefix_cache_status_response(
    prefix_cache_config: Any | None,
) -> worker_runtime_pb2.WorkerPrefixCacheStatus:
    configured_max_entries, configured_max_bytes = _prefix_cache_caps(prefix_cache_config)
    return worker_runtime_pb2.WorkerPrefixCacheStatus(
        implementation="disabled",
        enabled=False,
        configured_max_entries=configured_max_entries,
        configured_max_bytes=configured_max_bytes,
        status_code="disabled",
        status_message="prefix cache disabled by config",
    )


def _invalid_prefix_cache_status_response(
    prefix_cache_config: Any | None,
) -> worker_runtime_pb2.WorkerPrefixCacheStatus:
    configured_max_entries, configured_max_bytes = _prefix_cache_caps(prefix_cache_config)
    return worker_runtime_pb2.WorkerPrefixCacheStatus(
        implementation="unknown",
        enabled=True,
        configured_max_entries=configured_max_entries,
        configured_max_bytes=configured_max_bytes,
        status_code="invalid_status",
        status_message=_INVALID_PREFIX_CACHE_MESSAGE,
    )


def _invalid_prefix_cache_numeric_fields(prefix_cache: dict[str, Any]) -> list[str]:
    invalid_fields: list[str] = []

    for field in _PREFIX_CACHE_UINT32_FIELDS:
        if field not in prefix_cache:
            invalid_fields.append(field)
            continue

        value = prefix_cache[field]
        if not _valid_status_uint32(value):
            invalid_fields.append(field)

    for field in _PREFIX_CACHE_UINT64_FIELDS:
        if field not in prefix_cache:
            invalid_fields.append(field)
            continue

        value = prefix_cache[field]
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
            or value > _UINT64_MAX
        ):
            invalid_fields.append(field)

    return invalid_fields


def _prefix_cache_fingerprints(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []

    fingerprints: list[str] = []
    for fingerprint in value:
        if valid_cache_affinity_fingerprint(fingerprint):
            fingerprints.append(fingerprint)
            if len(fingerprints) >= _MAX_PREFIX_CACHE_FINGERPRINTS:
                break
    return fingerprints


def _prefix_cache_status_response(
    prefix_cache: Any,
    prefix_cache_config: Any | None,
) -> worker_runtime_pb2.WorkerPrefixCacheStatus:
    if not isinstance(prefix_cache, dict):
        return _invalid_prefix_cache_status_response(prefix_cache_config)

    status_code = _status_string(prefix_cache.get("status_code"))
    if status_code not in _PREFIX_CACHE_STATUS_CODES:
        return _invalid_prefix_cache_status_response(prefix_cache_config)

    if _invalid_prefix_cache_numeric_fields(prefix_cache):
        return _invalid_prefix_cache_status_response(prefix_cache_config)

    implementation = _status_string(prefix_cache.get("implementation"))
    if implementation == "":
        return _invalid_prefix_cache_status_response(prefix_cache_config)

    configured_max_entries, configured_max_bytes = _prefix_cache_caps(prefix_cache_config)
    fingerprints = _prefix_cache_fingerprints(prefix_cache.get("prefix_cache_fingerprints"))

    return worker_runtime_pb2.WorkerPrefixCacheStatus(
        implementation=implementation,
        enabled=True,
        entry_count=int(_status_uint64(prefix_cache.get("entry_count"))),
        total_bytes=_status_uint64(prefix_cache.get("total_bytes")),
        hits=_status_uint64(prefix_cache.get("hits")),
        misses=_status_uint64(prefix_cache.get("misses")),
        failures=_status_uint64(prefix_cache.get("failures")),
        stores=_status_uint64(prefix_cache.get("stores")),
        evictions=_status_uint64(prefix_cache.get("evictions")),
        configured_max_entries=configured_max_entries,
        configured_max_bytes=configured_max_bytes,
        status_code=status_code,
        status_message=_status_string(prefix_cache.get("status_message")),
        session_started_unix_ms=_status_uint64(prefix_cache.get("session_started_unix_ms")),
        prefix_cache_fingerprints=fingerprints,
    )


def _normalize_score_prefix_cache_diagnostics(
    status_code: str,
    score_tier: str,
    resident: bool,
) -> tuple[str, bool]:
    if status_code != "ok":
        return ("unknown", False)

    if score_tier == "resident_fingerprint" and resident:
        return (score_tier, resident)

    if score_tier == "resident_fingerprint" and not resident:
        return ("unknown", False)

    if resident:
        return ("unknown", False)

    return (score_tier, False)


def _score_prefix_cache_response(payload: Any) -> runtime_pb2.ScorePrefixCacheResponse:
    if not isinstance(payload, dict):
        return runtime_pb2.ScorePrefixCacheResponse(
            status_code="error",
            status_message="backend score prefix cache response was invalid",
            resident_fingerprint_match=False,
            score_tier="unknown",
            session_started_unix_ms=0,
        )

    status_code = _status_string(payload.get("status_code"))
    if status_code not in _SCORE_PREFIX_CACHE_STATUS_CODES:
        status_code = "error"

    score_tier = _status_string(payload.get("score_tier"))
    if score_tier not in _SCORE_PREFIX_CACHE_TIERS:
        score_tier = "unknown"

    resident = _status_bool(payload.get("resident_fingerprint_match"))
    score_tier, resident = _normalize_score_prefix_cache_diagnostics(
        status_code, score_tier, resident
    )

    status_message = _status_string(payload.get("status_message"))
    if status_code == "error":
        status_message = _SAFE_SCORE_PREFIX_CACHE_ERROR_MESSAGE

    return runtime_pb2.ScorePrefixCacheResponse(
        status_code=status_code,
        status_message=status_message,
        resident_fingerprint_match=resident,
        score_tier=score_tier,
        session_started_unix_ms=_status_uint64(payload.get("session_started_unix_ms")),
    )


class WorkerRuntimeServicer(worker_runtime_pb2_grpc.WorkerRuntimeServiceServicer):
    def __init__(
        self,
        backend: Backend,
        *,
        prefix_cache_config: Any | None = None,
        clock: Callable[[], float] = time.monotonic,
        cancel_tombstone_ttl_s: float = _DEFAULT_CANCEL_TOMBSTONE_TTL_S,
    ) -> None:
        self._backend = backend
        self._prefix_cache_config = prefix_cache_config
        self._cancel_entries: dict[str, CancelEntry] = {}
        self._lock = threading.Lock()
        self._clock = clock
        self._cancel_tombstone_ttl_s = cancel_tombstone_ttl_s

    def GetStatus(
        self, request: worker_runtime_pb2.WorkerStatusRequest, context: grpc.ServicerContext
    ) -> worker_runtime_pb2.WorkerStatusResponse:
        status = self._backend.status()
        health = self._backend.health()
        response = worker_runtime_pb2.WorkerStatusResponse(
            loaded=bool(status["loaded"]),
            active_request_count=int(status["active_request_count"]),
            ready=bool(health["ready"]),
            health_code=str(health["code"]),
            health_message=str(health["message"]),
            supports_prompt_token_ids=True,
        )
        memory_budget = _memory_budget_status_response(status.get("memory_budget"))
        if memory_budget is not None:
            response.memory_budget.CopyFrom(memory_budget)

        if _prefix_cache_disabled(self._prefix_cache_config):
            response.prefix_cache.CopyFrom(
                _disabled_prefix_cache_status_response(self._prefix_cache_config)
            )
            return response

        try:
            prefix_cache = self._backend.prefix_cache_status()
        except Exception as exc:
            response.prefix_cache.CopyFrom(
                _error_prefix_cache_status_response(
                    self._prefix_cache_config,
                    str(exc),
                )
            )
            return response

        response.prefix_cache.CopyFrom(
            _prefix_cache_status_response(
                prefix_cache,
                self._prefix_cache_config,
            )
        )
        return response

    def ScorePrefixCache(
        self,
        request: runtime_pb2.ScorePrefixCacheRequest,
        context: grpc.ServicerContext,
    ) -> runtime_pb2.ScorePrefixCacheResponse:
        del context

        if _prefix_cache_disabled(self._prefix_cache_config):
            return runtime_pb2.ScorePrefixCacheResponse(
                status_code="disabled",
                status_message="prefix cache disabled by config",
                resident_fingerprint_match=False,
                score_tier="unknown",
                session_started_unix_ms=0,
            )

        model_ref = getattr(request, "model_ref", None)
        if (
            model_ref is None
            or _status_string(getattr(model_ref, "model_id", "")) == ""
            or _status_string(getattr(model_ref, "version", "")) == ""
        ):
            return runtime_pb2.ScorePrefixCacheResponse(
                status_code="invalid_request",
                status_message="model_ref.model_id and model_ref.version are required",
                resident_fingerprint_match=False,
                score_tier="unknown",
                session_started_unix_ms=0,
            )

        fingerprint = _status_string(getattr(request, "cache_affinity_fingerprint", ""))
        if not valid_cache_affinity_fingerprint(fingerprint):
            return runtime_pb2.ScorePrefixCacheResponse(
                status_code="invalid_request",
                status_message=(
                    "cache_affinity_fingerprint must be hmac-sha256:<64 lowercase hex>"
                ),
                resident_fingerprint_match=False,
                score_tier="unknown",
                session_started_unix_ms=0,
            )

        try:
            score_payload = self._backend.score_prefix_cache(
                model_ref=model_ref,
                fingerprint=fingerprint,
                request_id=_status_string(getattr(request, "request_id", "")),
                deadline_unix_ms=_status_uint64(getattr(request, "deadline_unix_ms", 0)),
            )
        except BackendError:
            return runtime_pb2.ScorePrefixCacheResponse(
                status_code="error",
                status_message=_SAFE_SCORE_PREFIX_CACHE_ERROR_MESSAGE,
                resident_fingerprint_match=False,
                score_tier="unknown",
                session_started_unix_ms=0,
            )
        except Exception:
            return runtime_pb2.ScorePrefixCacheResponse(
                status_code="error",
                status_message=_SAFE_SCORE_PREFIX_CACHE_ERROR_MESSAGE,
                resident_fingerprint_match=False,
                score_tier="unknown",
                session_started_unix_ms=0,
            )

        return _score_prefix_cache_response(score_payload)

    def LoadModel(
        self, request: worker_runtime_pb2.LoadModelRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        logger.info(
            "load_model start model_id=%s version=%s model_path=%s",
            request.model_id,
            request.version,
            request.model_path,
        )

        # --- health gate: reject load when backend is unhealthy ---
        # This reads the one-shot probe result cached at backend construction.
        # No re-probe happens here — MLX runtime deps don't become healthy
        # mid-process, so the cached result is authoritative for the worker's
        # lifetime.
        health = self._backend.health()
        if not health["ready"]:
            code = health["code"] or "worker_unhealthy"
            message = health["message"] or "worker reported not ready"
            logger.error(
                "load_model rejected: backend unhealthy model_id=%s version=%s code=%s message=%s",
                request.model_id,
                request.version,
                code,
                message,
            )
            return common_pb2.Ack(ok=False, message=f"{code}: {message}")

        try:
            self._backend.load_model(
                model_id=request.model_id,
                version=request.version,
                model_path=request.model_path,
            )
        except BackendError as exc:
            logger.error(
                "load_model error model_id=%s version=%s code=%s message=%s",
                request.model_id,
                request.version,
                exc.code,
                exc.message,
            )
            return common_pb2.Ack(ok=False, message=f"{exc.code}: {exc.message}")

        logger.info("load_model ok model_id=%s version=%s", request.model_id, request.version)
        return common_pb2.Ack(ok=True, message="model loaded")

    def UnloadModel(
        self, request: runtime_pb2.UnloadModelRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        logger.info("unload_model start")
        try:
            self._backend.unload_model()
        except BackendError as exc:
            logger.error("unload_model error code=%s message=%s", exc.code, exc.message)
            return common_pb2.Ack(ok=False, message=f"{exc.code}: {exc.message}")

        logger.info("unload_model ok")
        return common_pb2.Ack(ok=True, message="model unloaded")

    def Generate(
        self, request: runtime_pb2.ExecuteInferenceRequest, context: grpc.ServicerContext
    ) -> Iterator[events_pb2.InferenceEvent]:
        logger.info("generate start request_id=%s", request.request_id)
        # --- claim or create cancel entry ---
        with self._lock:
            self._prune_expired_tombstones()
            entry = self._cancel_entries.get(request.request_id)
            if entry is None:
                entry = CancelEntry(event=threading.Event(), phase="active")
                self._cancel_entries[request.request_id] = entry
            else:
                # Tombstone -> active: reuse the (possibly set) event.
                entry.phase = "active"
                entry.expires_at_monotonic = None

        cancel_event = entry.event

        # Short-circuit if Cancel arrived before Generate.
        if cancel_event.is_set():
            yield build_failed_event("cancelled", "request cancelled", False)
            with self._lock:
                self._cancel_entries.pop(request.request_id, None)
            return

        generation_started = False
        terminal_emitted = False
        backend_iterator: Iterator[dict[str, Any]] | None = None
        try:
            self._backend.start_generation()
            generation_started = True

            fingerprint = getattr(request, "cache_affinity_fingerprint", "")
            if isinstance(fingerprint, str) and fingerprint != "":
                try:
                    self._backend.record_fingerprint(fingerprint)
                except Exception:
                    pass

            backend_iterator = self._backend.generate(request, cancel_event)
            try:
                for backend_event in backend_iterator:
                    try:
                        proto_event = build_inference_event(backend_event)
                    except BackendError as conv_exc:
                        # Invalid backend event -> synthesize terminal failure.
                        if not terminal_emitted:
                            yield build_failed_event(
                                conv_exc.code, conv_exc.message, conv_exc.retryable
                            )
                            terminal_emitted = True
                        break

                    yield proto_event

                    if _is_terminal_proto_event(proto_event):
                        terminal_emitted = True
                        break

                # Backend iterator ended without a terminal event.
                if not terminal_emitted:
                    yield build_failed_event(
                        "backend_missing_terminal",
                        "backend ended without terminal event",
                        False,
                    )
                    terminal_emitted = True
            finally:
                if backend_iterator is not None:
                    close = getattr(backend_iterator, "close", None)
                    if callable(close):
                        try:
                            close()
                        except Exception:
                            pass

        except BackendError as exc:
            if not terminal_emitted:
                yield build_failed_event(exc.code, exc.message, exc.retryable)
                terminal_emitted = True
        except Exception as exc:
            if not terminal_emitted:
                yield build_failed_event(
                    "backend_crash",
                    f"backend crashed: {exc}",
                    False,
                )
                terminal_emitted = True
        finally:
            logger.info("generate done request_id=%s", request.request_id)
            with self._lock:
                self._cancel_entries.pop(request.request_id, None)

            if generation_started:
                try:
                    self._backend.finish_generation()
                except Exception:
                    pass  # terminal already emitted or about to be; don't double-emit

    def Cancel(
        self, request: runtime_pb2.CancelInferenceRequest, context: grpc.ServicerContext
    ) -> common_pb2.Ack:
        logger.info("cancel request_id=%s", request.request_id)
        with self._lock:
            self._prune_expired_tombstones()
            entry = self._cancel_entries.get(request.request_id)
            if entry is None:
                event = threading.Event()
                event.set()
                self._cancel_entries[request.request_id] = CancelEntry(
                    event=event,
                    phase="tombstone",
                    expires_at_monotonic=self._clock() + self._cancel_tombstone_ttl_s,
                )
            else:
                entry.event.set()

        return common_pb2.Ack(ok=True, message="cancel accepted")

    # -- internal helpers --

    def _prune_expired_tombstones(self) -> None:
        """Remove expired tombstone entries.  Must be called with ``_lock`` held."""
        now = self._clock()
        expired = [
            rid
            for rid, entry in self._cancel_entries.items()
            if entry.phase == "tombstone"
            and entry.expires_at_monotonic is not None
            and entry.expires_at_monotonic <= now
        ]
        for rid in expired:
            del self._cancel_entries[rid]


def _derive_server_max_workers(generation_config: Any | None) -> int:
    mode = (
        getattr(generation_config, "mode", "stream") if generation_config is not None else "stream"
    )
    configured = (
        getattr(generation_config, "max_concurrent_generations", 1)
        if generation_config is not None
        else 1
    )

    concurrency = 1
    if mode == "batch":
        try:
            if configured == "auto":
                concurrency = int(getattr(generation_config, "auto_max_concurrent_generations", 1))
            else:
                concurrency = int(configured)
        except (TypeError, ValueError):
            concurrency = 1

    concurrency = max(1, concurrency)
    derived = concurrency + _DEFAULT_GRPC_WORKER_HEADROOM
    return max(_DEFAULT_GRPC_WORKERS_MIN, derived)


def build_server(
    backend_name: str,
    *,
    backend_factory: Callable[..., Backend] = build_backend,
    prefix_cache_config: Any | None = None,
    generation_config: Any | None = None,
    memory_budget_config: Any | None = None,
    clock: Callable[[], float] = time.monotonic,
    cancel_tombstone_ttl_s: float = _DEFAULT_CANCEL_TOMBSTONE_TTL_S,
) -> grpc.Server:
    backend = backend_factory(
        backend_name,
        prefix_cache_config=prefix_cache_config,
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )
    max_workers = _derive_server_max_workers(generation_config)
    server = grpc.server(ThreadPoolExecutor(max_workers=max_workers))
    worker_runtime_pb2_grpc.add_WorkerRuntimeServiceServicer_to_server(
        WorkerRuntimeServicer(
            backend,
            prefix_cache_config=prefix_cache_config,
            clock=clock,
            cancel_tombstone_ttl_s=cancel_tombstone_ttl_s,
        ),
        server,
    )
    return server


def serve(
    socket_path: str,
    backend_name: str,
    *,
    prefix_cache_config: Any | None = None,
    generation_config: Any | None = None,
    memory_budget_config: Any | None = None,
) -> None:
    logger.info("worker starting backend=%s socket_path=%s", backend_name, socket_path)
    socket = Path(socket_path)
    socket.parent.mkdir(parents=True, exist_ok=True)

    if socket.exists():
        socket.unlink()

    server = build_server(
        backend_name,
        prefix_cache_config=prefix_cache_config,
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )
    bind_target = f"unix://{socket_path}"
    bound_port = server.add_insecure_port(bind_target)

    if bound_port == 0:
        raise RuntimeError(f"failed to bind worker socket at {socket_path}")

    previous_handlers = install_signal_handlers(server)
    server.start()
    logger.info("worker listening backend=%s socket_path=%s", backend_name, socket_path)

    try:
        server.wait_for_termination()
    finally:
        logger.info("worker stopping socket_path=%s", socket_path)
        restore_signal_handlers(previous_handlers)
        server.stop(grace=0).wait(timeout=1.0)
        if socket.exists():
            socket.unlink()


# ---------------------------------------------------------------------------
# Event building
# ---------------------------------------------------------------------------

# Terminal proto event kinds.
_TERMINAL_ONEOFS = frozenset({"completed", "failed"})
_VALID_FINISH_REASONS = frozenset(
    {"FINISH_REASON_STOP", "FINISH_REASON_LENGTH", "FINISH_REASON_TOOL_CALLS"}
)


def _is_terminal_proto_event(event: events_pb2.InferenceEvent) -> bool:
    return event.WhichOneof("event") in _TERMINAL_ONEOFS


def build_inference_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    """Convert a backend dict event to a proto ``InferenceEvent``.

    Raises ``BackendError`` for invalid or unsupported event shapes so the
    caller can synthesize a terminal failure.
    """
    kind = event.get("kind")

    if kind == "accepted":
        raise BackendError(
            "backend_invalid_event",
            "backend must not emit accepted events",
            False,
        )

    if kind == "output_text_delta":
        delta = event.get("delta")
        if not isinstance(delta, str):
            raise BackendError(
                "backend_invalid_event",
                f"output_text_delta.delta must be str, got {type(delta).__name__}",
                False,
            )
        return events_pb2.InferenceEvent(output_text_delta=events_pb2.OutputTextDelta(delta=delta))

    if kind == "progress":
        stage = event.get("stage", "")
        message = event.get("message", "")
        if not isinstance(stage, str) or not stage:
            raise BackendError(
                "backend_invalid_event",
                "progress.stage must be a non-empty string",
                False,
            )
        if not isinstance(message, str) or not message:
            raise BackendError(
                "backend_invalid_event",
                "progress.message must be a non-empty string",
                False,
            )
        return events_pb2.InferenceEvent(progress=events_pb2.Progress(stage=stage, message=message))

    if kind == "usage":
        return _build_usage_event(event)

    if kind == "tool_call_delta":
        return _build_tool_call_delta_event(event)

    if kind == "completed":
        return _build_completed_event(event)

    if kind == "failed":
        return _build_failed_from_dict(event)

    raise BackendError(
        "backend_invalid_event",
        f"unsupported event kind: {kind}",
        False,
    )


def _validate_token_usage(usage: dict[str, Any]) -> common_pb2.TokenUsage:
    """Validate and convert a token usage dict to proto."""
    input_tokens = usage.get("input_tokens")
    output_tokens = usage.get("output_tokens")
    total_tokens = usage.get("total_tokens")

    for name, value in [
        ("input_tokens", input_tokens),
        ("output_tokens", output_tokens),
        ("total_tokens", total_tokens),
    ]:
        if not isinstance(value, int) or value < 0:
            raise BackendError(
                "backend_invalid_event",
                f"usage.{name} must be a non-negative integer, got {value!r}",
                False,
            )

    if total_tokens != input_tokens + output_tokens:
        raise BackendError(
            "backend_invalid_event",
            "usage.total_tokens "
            f"({total_tokens}) != input_tokens ({input_tokens}) + "
            f"output_tokens ({output_tokens})",
            False,
        )

    return common_pb2.TokenUsage(
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total_tokens,
    )


def _build_usage_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    usage = event.get("usage")
    if not isinstance(usage, dict):
        raise BackendError(
            "backend_invalid_event",
            "usage event must contain a 'usage' dict",
            False,
        )
    return events_pb2.InferenceEvent(
        usage=events_pb2.UsageUpdate(usage=_validate_token_usage(usage))
    )


def _build_tool_call_delta_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    tool_call_id = event.get("tool_call_id")
    if not isinstance(tool_call_id, str) or not tool_call_id:
        raise BackendError(
            "backend_invalid_event",
            "tool_call_delta.tool_call_id must be a non-empty string",
            False,
        )

    delta = _normalize_tool_call_delta(event.get("delta"))
    return events_pb2.InferenceEvent(
        tool_call_delta=events_pb2.ToolCallDelta(
            tool_call_id=tool_call_id,
            delta_json=json.dumps(delta, ensure_ascii=False),
        )
    )


def _normalize_tool_call_delta(delta: Any) -> dict[str, Any]:
    if not isinstance(delta, dict):
        raise BackendError(
            "backend_invalid_event",
            "tool_call_delta.delta must be a dict",
            False,
        )

    unknown_delta_keys = sorted(set(delta) - {"index", "type", "function"})
    if unknown_delta_keys:
        raise BackendError(
            "backend_invalid_event",
            f"tool_call_delta.delta has unknown keys: {unknown_delta_keys}",
            False,
        )

    index = delta.get("index")
    if isinstance(index, bool) or not isinstance(index, int) or index < 0:
        raise BackendError(
            "backend_invalid_event",
            f"tool_call_delta.delta.index must be a non-negative integer, got {index!r}",
            False,
        )

    normalized: dict[str, Any] = {"index": index}

    delta_type = delta.get("type")
    if delta_type is not None:
        if delta_type != "function":
            raise BackendError(
                "backend_invalid_event",
                f"tool_call_delta.delta.type must be 'function', got {delta_type!r}",
                False,
            )
        normalized["type"] = delta_type

    function_delta = delta.get("function")
    if function_delta is not None:
        if not isinstance(function_delta, dict):
            raise BackendError(
                "backend_invalid_event",
                "tool_call_delta.delta.function must be a dict when present",
                False,
            )

        unknown_function_keys = sorted(
            set(function_delta) - {"name", "arguments_delta", "arguments"}
        )
        if unknown_function_keys:
            raise BackendError(
                "backend_invalid_event",
                f"tool_call_delta.delta.function has unknown keys: {unknown_function_keys}",
                False,
            )
        if "arguments_delta" in function_delta and "arguments" in function_delta:
            raise BackendError(
                "backend_invalid_event",
                "tool_call_delta.delta.function cannot include both arguments_delta and arguments",
                False,
            )

        normalized_function: dict[str, Any] = {}
        name = function_delta.get("name")
        if name is not None:
            if not isinstance(name, str) or not name:
                raise BackendError(
                    "backend_invalid_event",
                    f"tool_call_delta.delta.function.name must be a non-empty string, got {name!r}",
                    False,
                )
            normalized_function["name"] = name

        arguments_delta = function_delta.get("arguments_delta")
        arguments = function_delta.get("arguments")
        if arguments_delta is not None:
            if not isinstance(arguments_delta, str):
                raise BackendError(
                    "backend_invalid_event",
                    "tool_call_delta.delta.function.arguments_delta must be a string",
                    False,
                )
            normalized_function["arguments_delta"] = arguments_delta
        elif arguments is not None:
            if not isinstance(arguments, str):
                raise BackendError(
                    "backend_invalid_event",
                    "tool_call_delta.delta.function.arguments must be a string",
                    False,
                )
            normalized_function["arguments"] = arguments

        if normalized_function:
            normalized["function"] = normalized_function

    if len(normalized) == 1:
        raise BackendError(
            "backend_invalid_event",
            "tool_call_delta.delta must include type or function content",
            False,
        )

    return normalized


def _build_completed_event(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    usage_dict = event.get("usage")
    if not isinstance(usage_dict, dict):
        raise BackendError(
            "backend_invalid_event",
            "completed event must contain a 'usage' dict",
            False,
        )

    finish_reason = event.get("finish_reason", "FINISH_REASON_STOP")
    if not isinstance(finish_reason, str) or finish_reason not in _VALID_FINISH_REASONS:
        raise BackendError(
            "backend_invalid_event",
            "completed.finish_reason must be one of "
            f"{sorted(_VALID_FINISH_REASONS)}, got {finish_reason!r}",
            False,
        )

    return events_pb2.InferenceEvent(
        completed=events_pb2.Completed(
            finish_reason=finish_reason,
            usage=_validate_token_usage(usage_dict),
        )
    )


def _build_failed_from_dict(event: dict[str, Any]) -> events_pb2.InferenceEvent:
    code = event.get("code", "")
    message = event.get("message", "")
    retryable = event.get("retryable", False)
    if not isinstance(code, str) or not code:
        raise BackendError(
            "backend_invalid_event",
            "failed.code must be a non-empty string",
            False,
        )
    if not isinstance(message, str) or not message:
        raise BackendError(
            "backend_invalid_event",
            "failed.message must be a non-empty string",
            False,
        )
    if not isinstance(retryable, bool):
        raise BackendError(
            "backend_invalid_event",
            f"failed.retryable must be bool, got {type(retryable).__name__}",
            False,
        )
    return build_failed_event(code, message, retryable)


def build_failed_event(code: str, message: str, retryable: bool) -> events_pb2.InferenceEvent:
    return events_pb2.InferenceEvent(
        failed=events_pb2.Failed(code=code, message=message, retryable=retryable)
    )


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------


def install_signal_handlers(server: grpc.Server) -> dict[signal.Signals, Any]:
    previous_handlers: dict[signal.Signals, Any] = {}

    def _request_shutdown(_signum: int, _frame: FrameType | None) -> None:
        server.stop(grace=0)

    for signum in (signal.SIGTERM, signal.SIGINT):
        previous_handlers[signum] = signal.getsignal(signum)
        signal.signal(signum, _request_shutdown)

    return previous_handlers


def restore_signal_handlers(previous_handlers: dict[signal.Signals, Any]) -> None:
    for signum, handler in previous_handlers.items():
        signal.signal(signum, handler)
