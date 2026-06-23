from __future__ import annotations

import json
import logging
import re
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NotRequired, Protocol, TypedDict, runtime_checkable

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class BackendError(Exception):
    code: str
    message: str
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


_UINT32_MAX = 4_294_967_295
_UINT64_MAX = 18_446_744_073_709_551_615
_MAX_FINGERPRINT_BUFFER_SIZE = 64
_DEFAULT_FINGERPRINT_BUFFER_SIZE = 8
_FINGERPRINT_RE = re.compile(r"^hmac-sha256:[a-f0-9]{64}$")
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


class BackendMemoryBudgetStatus(TypedDict):
    mode: str
    budget_available: bool
    headroom_available: bool
    status_code: str
    status_message: str
    source: str
    max_recommended_working_set_size_bytes: int
    utilization: float
    target_working_set_bytes: int
    overhead_bytes: int
    resident_memory_bytes: int
    estimated_headroom_bytes: int
    kv_cache_bytes_per_token: int
    prefill_workspace_bytes_per_token: int


class BackendPrefixCacheStatus(TypedDict):
    implementation: str
    enabled: bool
    entry_count: int
    total_bytes: int
    hits: int
    misses: int
    failures: int
    stores: int
    evictions: int
    configured_max_entries: int
    configured_max_bytes: int
    status_code: str
    status_message: str
    session_started_unix_ms: int
    prefix_cache_fingerprints: NotRequired[list[str]]


class _NormalizedPrefixCacheStats(TypedDict):
    implementation: str
    entry_count: int
    total_bytes: int
    hits: int
    misses: int
    failures: int
    stores: int
    evictions: int


class BackendPrefixCacheScore(TypedDict):
    status_code: str
    status_message: str
    resident_fingerprint_match: bool
    score_tier: str
    session_started_unix_ms: int


class BackendStatus(TypedDict):
    loaded: bool
    active_request_count: int
    max_concurrency: NotRequired[int]
    memory_budget: NotRequired[BackendMemoryBudgetStatus]


class BackendHealth(TypedDict):
    ready: bool
    code: str
    message: str


@runtime_checkable
class Backend(Protocol):
    """Structural contract that all worker backends must satisfy."""

    def status(self) -> BackendStatus: ...
    def health(self) -> BackendHealth: ...
    def prefix_cache_status(self) -> BackendPrefixCacheStatus: ...
    def load_model(self, *, model_id: str, version: str, model_path: str) -> None: ...
    def unload_model(self) -> None: ...
    def start_generation(self) -> None: ...
    def finish_generation(self) -> None: ...
    def record_fingerprint(self, fingerprint: str) -> None: ...
    def get_fingerprints(self) -> list[str]: ...
    def score_prefix_cache(
        self,
        *,
        model_ref: Any,
        fingerprint: str,
        request_id: str,
        deadline_unix_ms: int,
    ) -> BackendPrefixCacheScore: ...
    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]: ...


class StubBackend:
    def __init__(
        self, *, max_fingerprint_buffer_size: int = _DEFAULT_FINGERPRINT_BUFFER_SIZE
    ) -> None:
        self._loaded_model: tuple[str, str, str] | None = None
        self._active_request_count = 0
        self._max_fingerprint_buffer_size = _normalize_fingerprint_buffer_size(
            max_fingerprint_buffer_size
        )
        self._fingerprint_buffer: list[str] = []
        self._lock = threading.Lock()

    def status(self) -> BackendStatus:
        with self._lock:
            return BackendStatus(
                loaded=self._loaded_model is not None,
                active_request_count=self._active_request_count,
                max_concurrency=1,
            )

    def health(self) -> BackendHealth:
        return BackendHealth(ready=True, code="", message="")

    def prefix_cache_status(self) -> BackendPrefixCacheStatus:
        return _base_prefix_cache_status(
            status_code="unavailable",
            status_message="prefix cache status unavailable for backend",
            prefix_cache_fingerprints=self.get_fingerprints(),
        )

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        logger.info("stub load_model model_id=%s version=%s", model_id, version)
        if not Path(model_path).exists():
            raise BackendError("model_path_missing", f"model path is missing: {model_path}")

        with self._lock:
            self._loaded_model = (model_id, version, model_path)
        logger.info("stub load_model ok model_id=%s version=%s", model_id, version)

    def unload_model(self) -> None:
        logger.info("stub unload_model")
        with self._lock:
            self._loaded_model = None
            self._fingerprint_buffer.clear()
        logger.info("stub unload_model ok")

    def start_generation(self) -> None:
        with self._lock:
            if self._loaded_model is None:
                raise BackendError("model_not_loaded", "model is not loaded")

            if self._active_request_count > 0:
                raise BackendError("worker_busy", "worker already has an active generation")

            self._active_request_count = 1

    def finish_generation(self) -> None:
        with self._lock:
            self._active_request_count = max(0, self._active_request_count - 1)

    def record_fingerprint(self, fingerprint: str) -> None:
        if not valid_cache_affinity_fingerprint(fingerprint):
            return

        with self._lock:
            if self._loaded_model is None:
                return
            _append_fingerprint(
                self._fingerprint_buffer,
                fingerprint,
                self._max_fingerprint_buffer_size,
            )

    def get_fingerprints(self) -> list[str]:
        with self._lock:
            return _fingerprint_snapshot(self._fingerprint_buffer)

    def score_prefix_cache(
        self,
        *,
        model_ref: Any,
        fingerprint: str,
        request_id: str,
        deadline_unix_ms: int,
    ) -> BackendPrefixCacheScore:
        del request_id

        with self._lock:
            loaded_model = self._loaded_model

        if loaded_model is None:
            return _score_prefix_cache_response(
                status_code="unavailable",
                status_message="model session is not loaded",
            )

        loaded_model_id, loaded_version, _ = loaded_model
        if (
            getattr(model_ref, "model_id", "") != loaded_model_id
            or getattr(model_ref, "version", "") != loaded_version
        ):
            return _score_prefix_cache_response(
                status_code="model_not_loaded",
                status_message="model is not loaded on this worker",
            )

        if not valid_cache_affinity_fingerprint(fingerprint):
            return _score_prefix_cache_response(
                status_code="invalid_request",
                status_message="cache affinity fingerprint is invalid",
            )

        if deadline_unix_ms > 0 and int(time.time() * 1000) > deadline_unix_ms:
            return _score_prefix_cache_response(
                status_code="timeout",
                status_message="score prefix cache deadline exceeded",
            )

        return _score_prefix_cache_response(
            status_code="unavailable",
            status_message="prefix cache score unavailable for backend",
        )

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        return _stub_generate(request, cancel_event)


def _stub_generate(request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
    """Deterministic generation shared by StubBackend and MLXBackend (until Task 3)."""
    metadata = decode_metadata(getattr(request, "metadata_json", b""))
    chunks = metadata.get("worker_chunks") or ["mlx ", "ready"]
    delay_ms = safe_int(metadata.get("worker_delay_ms", 0))

    for chunk in chunks:
        if cancel_event.is_set():
            yield cancelled_event()
            return

        if delay_ms > 0:
            if cancel_event.wait(delay_ms / 1000):
                yield cancelled_event()
                return

        yield {"kind": "output_text_delta", "delta": str(chunk)}

    output_tokens = len(chunks)
    input_tokens = int(getattr(request, "input_tokens", 0))
    yield {
        "kind": "completed",
        "finish_reason": "FINISH_REASON_STOP",
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
        },
    }


class MLXBackend:
    """Real MLX backend with session-based model lifecycle and generation.

    Health is probed once at construction (one-shot ``probe_mlx_environment``)
    and cached forever.  When DI seams are injected (test mode), the probe is
    skipped and health defaults to ready.  An explicit ``health_probe``
    callable overrides both paths.

    **Why one-shot / no re-probe:**  The probe validates that mandatory
    Python dependencies (``mlx.core``, ``mlx_lm``, ``transformers``) can be
    imported and that Metal tensor allocation works.  These are process-level
    invariants: if they fail at construction, they won't self-heal later.
    Sleep/wake GPU recovery is handled at the OS level before the Python
    process is affected; if Metal truly becomes unavailable mid-process, the
    worker should be killed and restarted by the node agent.
    """

    def __init__(
        self,
        *,
        session_loader: Callable[..., Any] | None = None,
        session_unloader: Callable[..., None] | None = None,
        generation_runner: Callable[..., Iterator[dict[str, Any]]] | None = None,
        health_probe: Callable[[], Any] | None = None,
        prefix_cache_config: Any | None = None,
        generation_config: Any | None = None,
        memory_budget_config: Any | None = None,
        batch_runtime_factory: Callable[[Any], Any] | None = None,
    ) -> None:
        from orchard_worker_mlx.model_loader import (
            DEFAULT_GENERATION_RUNTIME_CONFIG,
            DEFAULT_MEMORY_BUDGET_CONFIG,
            DEFAULT_PREFIX_CACHE_LOAD_CONFIG,
            MLXEnvironmentHealth,
            probe_mlx_environment,
        )
        from orchard_worker_mlx.model_loader import (
            load_session as _load_session,
        )
        from orchard_worker_mlx.model_loader import (
            unload_session as _unload_session,
        )

        self._session_loader = session_loader or _load_session
        self._session_unloader = session_unloader or _unload_session
        self._generation_runner = generation_runner or _default_generation_runner()
        self._generation_runner_injected = generation_runner is not None
        self._batch_runtime_factory = batch_runtime_factory or _default_batch_runtime_factory()
        self._prefix_cache_config = prefix_cache_config or DEFAULT_PREFIX_CACHE_LOAD_CONFIG
        self._max_fingerprint_buffer_size = _fingerprint_buffer_size_from_config(
            self._prefix_cache_config
        )
        self._generation_config = generation_config or DEFAULT_GENERATION_RUNTIME_CONFIG
        self._memory_budget_config = memory_budget_config or DEFAULT_MEMORY_BUDGET_CONFIG
        self._session: Any | None = None
        self._batch_runtime: Any | None = None
        self._max_concurrent_requests = 1
        self._active_request_count = 0
        self._unloading = False
        self._lock = threading.Lock()

        # --- one-shot health probe, cached forever ---
        has_injected_seams = (
            session_loader is not None
            or session_unloader is not None
            or generation_runner is not None
        )

        if health_probe is not None:
            try:
                env = health_probe()
            except Exception as exc:
                env = MLXEnvironmentHealth(
                    ready=False,
                    code="metal_unavailable",
                    message=f"health probe failed: {exc}",
                )
        elif has_injected_seams:
            # Test seams injected — skip real MLX probe.
            env = MLXEnvironmentHealth(ready=True)
        else:
            env = probe_mlx_environment()

        self._health: BackendHealth = BackendHealth(
            ready=env.ready,
            code=env.code,
            message=env.message,
        )

    def status(self) -> BackendStatus:
        with self._lock:
            loaded = self._session is not None
            status = BackendStatus(
                loaded=loaded,
                active_request_count=self._active_request_count,
                max_concurrency=self._max_concurrent_requests,
            )
            if loaded and self._session is not None:
                budget = self._session.memory_budget_status
                status["memory_budget"] = BackendMemoryBudgetStatus(
                    mode=budget.mode,
                    budget_available=budget.budget_available,
                    headroom_available=budget.headroom_available,
                    status_code=budget.status_code,
                    status_message=budget.status_message,
                    source=budget.source,
                    max_recommended_working_set_size_bytes=budget.max_recommended_working_set_size_bytes,
                    utilization=budget.utilization,
                    target_working_set_bytes=budget.target_working_set_bytes,
                    overhead_bytes=budget.overhead_bytes,
                    resident_memory_bytes=budget.resident_memory_bytes,
                    estimated_headroom_bytes=budget.estimated_headroom_bytes,
                    kv_cache_bytes_per_token=budget.kv_cache_bytes_per_token,
                    prefill_workspace_bytes_per_token=budget.prefill_workspace_bytes_per_token,
                )
            return status

    def health(self) -> BackendHealth:
        return BackendHealth(
            ready=self._health["ready"],
            code=self._health["code"],
            message=self._health["message"],
        )

    def prefix_cache_status(self) -> BackendPrefixCacheStatus:
        with self._lock:
            session = self._session
            fingerprints = _fingerprint_snapshot(
                getattr(session, "prefix_cache_fingerprints", []) if session is not None else []
            )

        config_max_entries = _status_uint32(getattr(self._prefix_cache_config, "max_entries", 0))
        config_max_bytes = _status_uint64(getattr(self._prefix_cache_config, "max_bytes", 0))

        if session is None:
            return _base_prefix_cache_status(
                configured_max_entries=config_max_entries,
                configured_max_bytes=config_max_bytes,
                status_code="unavailable",
                status_message="model session is not loaded",
                prefix_cache_fingerprints=fingerprints,
            )

        prefix_cache = getattr(session, "prefix_cache", None)
        if prefix_cache is None:
            return _base_prefix_cache_status(
                configured_max_entries=config_max_entries,
                configured_max_bytes=config_max_bytes,
                status_code="unavailable",
                status_message="prefix cache is not available",
                session_started_unix_ms=_status_uint64(
                    getattr(session, "session_started_unix_ms", 0)
                ),
                prefix_cache_fingerprints=fingerprints,
            )

        try:
            stats = prefix_cache.stats()
        except Exception as exc:
            return _base_prefix_cache_status(
                configured_max_entries=config_max_entries,
                configured_max_bytes=config_max_bytes,
                status_code="error",
                status_message=f"prefix cache stats read failed: {exc}",
                session_started_unix_ms=_status_uint64(
                    getattr(session, "session_started_unix_ms", 0)
                ),
                prefix_cache_fingerprints=fingerprints,
            )

        normalized_stats = _normalize_prefix_cache_stats(stats)
        if normalized_stats is None:
            return _base_prefix_cache_status(
                configured_max_entries=config_max_entries,
                configured_max_bytes=config_max_bytes,
                status_code="invalid_status",
                status_message="prefix cache stats payload was invalid",
                session_started_unix_ms=_status_uint64(
                    getattr(session, "session_started_unix_ms", 0)
                ),
                prefix_cache_fingerprints=fingerprints,
            )

        return BackendPrefixCacheStatus(
            implementation=normalized_stats["implementation"],
            enabled=True,
            entry_count=normalized_stats["entry_count"],
            total_bytes=normalized_stats["total_bytes"],
            hits=normalized_stats["hits"],
            misses=normalized_stats["misses"],
            failures=normalized_stats["failures"],
            stores=normalized_stats["stores"],
            evictions=normalized_stats["evictions"],
            configured_max_entries=config_max_entries,
            configured_max_bytes=config_max_bytes,
            status_code="ok",
            status_message="",
            session_started_unix_ms=_status_uint64(getattr(session, "session_started_unix_ms", 0)),
            prefix_cache_fingerprints=fingerprints,
        )

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        from orchard_worker_mlx.model_loader import ModelLoaderError

        logger.info("mlx load_model model_id=%s version=%s", model_id, version)
        with self._lock:
            if self._unloading:
                raise BackendError(
                    "model_unloading",
                    "model unload is in progress",
                    True,
                )
            if self._session is not None:
                # Idempotent same-model reload.
                s = self._session
                if (
                    s.manifest.model_id == model_id
                    and s.manifest.version == version
                    and str(s.bundle_path) == str(Path(model_path))
                ):
                    return
                raise BackendError(
                    "model_already_loaded",
                    "a different model is already loaded "
                    f"({s.manifest.model_id}@{s.manifest.version})",
                )

            try:
                session = self._session_loader(
                    model_id=model_id,
                    version=version,
                    model_path=model_path,
                    prefix_cache_config=self._prefix_cache_config,
                    generation_config=self._generation_config,
                    memory_budget_config=self._memory_budget_config,
                )
            except ModelLoaderError as exc:
                raise BackendError(exc.code, exc.message, exc.retryable) from exc

            batch_runtime = None
            max_concurrent_requests = 1

            if not self._generation_runner_injected and session.generation_config.mode == "batch":
                try:
                    batch_runtime = self._batch_runtime_factory(session)
                    max_concurrent_requests = (
                        session.generation_config.resolved_max_concurrent_generations(
                            session.manifest,
                            session.memory_budget_status,
                        )
                    )
                    logger.info(
                        "mlx batch generation enabled max_concurrent_generations=%d "
                        "configured=%s auto_cap=%d",
                        max_concurrent_requests,
                        session.generation_config.max_concurrent_generations,
                        session.generation_config.auto_max_concurrent_generations,
                    )
                except Exception as exc:
                    try:
                        self._session_unloader(session)
                    except Exception:
                        pass

                    raise BackendError(
                        "batch_runtime_unavailable",
                        f"batch runtime initialization failed: {exc}",
                        False,
                    ) from exc

            self._session = session
            self._batch_runtime = batch_runtime
            self._max_concurrent_requests = max_concurrent_requests
        logger.info("mlx load_model ok model_id=%s version=%s", model_id, version)

    def unload_model(self) -> None:
        logger.info("mlx unload_model")
        with self._lock:
            if self._unloading:
                raise BackendError(
                    "model_unloading",
                    "model unload is in progress",
                    True,
                )
            if self._session is None:
                return
            if self._active_request_count > 0:
                raise BackendError(
                    "model_busy",
                    "cannot unload: active generation in progress",
                )
            self._unloading = True
            session = self._session
            batch_runtime = self._batch_runtime

        try:
            if batch_runtime is not None:
                try:
                    batch_runtime.close()
                except BackendError:
                    raise
                except Exception as exc:
                    raise BackendError(
                        "batch_runtime_close_failed",
                        f"batch runtime close failed: {exc}",
                        True,
                    ) from exc

            with self._lock:
                if self._session is session:
                    self._session = None
                    self._batch_runtime = None
                    self._max_concurrent_requests = 1

            # Outside lock: best-effort cleanup.
            try:
                self._session_unloader(session)
            except Exception:
                pass
        finally:
            with self._lock:
                self._unloading = False
        logger.info("mlx unload_model ok")

    def start_generation(self) -> None:
        with self._lock:
            if self._unloading:
                raise BackendError(
                    "model_unloading",
                    "model unload is in progress",
                    True,
                )
            if self._session is None:
                raise BackendError("model_not_loaded", "model is not loaded")
            if self._active_request_count >= self._max_concurrent_requests:
                raise BackendError("worker_busy", "worker already has an active generation")
            self._active_request_count += 1

    def finish_generation(self) -> None:
        with self._lock:
            self._active_request_count = max(0, self._active_request_count - 1)

    def record_fingerprint(self, fingerprint: str) -> None:
        if not valid_cache_affinity_fingerprint(fingerprint):
            return

        with self._lock:
            session = self._session
            if session is None:
                return
            buffer = getattr(session, "prefix_cache_fingerprints", None)
            if not isinstance(buffer, list):
                return
            _append_fingerprint(buffer, fingerprint, self._max_fingerprint_buffer_size)

    def get_fingerprints(self) -> list[str]:
        with self._lock:
            session = self._session
            if session is None:
                return []
            return _fingerprint_snapshot(getattr(session, "prefix_cache_fingerprints", []))

    def score_prefix_cache(
        self,
        *,
        model_ref: Any,
        fingerprint: str,
        request_id: str,
        deadline_unix_ms: int,
    ) -> BackendPrefixCacheScore:
        del request_id

        session_started_unix_ms = 0
        if getattr(self._prefix_cache_config, "mode", "") == "disabled":
            return _score_prefix_cache_response(
                status_code="disabled",
                status_message="prefix cache disabled by config",
            )

        with self._lock:
            session = self._session

        if session is None:
            return _score_prefix_cache_response(
                status_code="unavailable",
                status_message="model session is not loaded",
            )

        session_started_unix_ms = _status_uint64(getattr(session, "session_started_unix_ms", 0))

        if getattr(model_ref, "model_id", "") != getattr(
            session.manifest, "model_id", ""
        ) or getattr(model_ref, "version", "") != getattr(session.manifest, "version", ""):
            return _score_prefix_cache_response(
                status_code="model_not_loaded",
                status_message="model is not loaded on this worker",
                session_started_unix_ms=session_started_unix_ms,
            )

        if not valid_cache_affinity_fingerprint(fingerprint):
            return _score_prefix_cache_response(
                status_code="invalid_request",
                status_message="cache affinity fingerprint is invalid",
                session_started_unix_ms=session_started_unix_ms,
            )

        if deadline_unix_ms > 0 and int(time.time() * 1000) > deadline_unix_ms:
            return _score_prefix_cache_response(
                status_code="timeout",
                status_message="score prefix cache deadline exceeded",
                session_started_unix_ms=session_started_unix_ms,
            )

        prefix_cache = getattr(session, "prefix_cache", None)
        if prefix_cache is None:
            return _score_prefix_cache_response(
                status_code="unavailable",
                status_message="prefix cache is not available",
                session_started_unix_ms=session_started_unix_ms,
            )

        try:
            score = prefix_cache.score(fingerprint)
        except Exception:
            return _score_prefix_cache_response(
                status_code="error",
                status_message="score prefix cache unavailable",
                session_started_unix_ms=session_started_unix_ms,
            )

        resident = bool(score.get("resident"))
        tier_raw = score.get("tier")
        tier = (
            tier_raw
            if isinstance(tier_raw, str) and tier_raw in _SCORE_PREFIX_CACHE_TIERS
            else "unknown"
        )

        if (
            not resident
            and tier == "no_match"
            and fingerprint
            in _fingerprint_snapshot(getattr(session, "prefix_cache_fingerprints", []))
        ):
            tier = "recent_fingerprint_only"

        return _score_prefix_cache_response(
            status_code="ok",
            resident_fingerprint_match=resident,
            score_tier=tier,
            session_started_unix_ms=session_started_unix_ms,
        )

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        with self._lock:
            session = self._session
            batch_runtime = self._batch_runtime
        if session is None:
            raise BackendError("model_not_loaded", "model is not loaded")

        if batch_runtime is not None:
            from orchard_worker_mlx.generation import generate_events

            yield from generate_events(
                session,
                request,
                cancel_event,
                deps=batch_runtime.generation_deps(),
            )
            return

        yield from self._generation_runner(session, request, cancel_event)


def _default_generation_runner() -> Callable[..., Iterator[dict[str, Any]]]:
    """Lazily import the real generation runner."""
    from orchard_worker_mlx.generation import generate_events

    return generate_events


def _default_batch_runtime_factory() -> Callable[[Any], Any]:
    """Lazily import the real shared batch runtime factory."""
    from orchard_worker_mlx.generation import BatchGeneratorRuntime

    return BatchGeneratorRuntime


def _base_prefix_cache_status(
    *,
    implementation: str = "unknown",
    enabled: bool = True,
    entry_count: int = 0,
    total_bytes: int = 0,
    hits: int = 0,
    misses: int = 0,
    failures: int = 0,
    stores: int = 0,
    evictions: int = 0,
    configured_max_entries: int = 0,
    configured_max_bytes: int = 0,
    status_code: str,
    status_message: str,
    session_started_unix_ms: int = 0,
    prefix_cache_fingerprints: list[str] | None = None,
) -> BackendPrefixCacheStatus:
    return BackendPrefixCacheStatus(
        implementation=implementation,
        enabled=enabled,
        entry_count=entry_count,
        total_bytes=total_bytes,
        hits=hits,
        misses=misses,
        failures=failures,
        stores=stores,
        evictions=evictions,
        configured_max_entries=configured_max_entries,
        configured_max_bytes=configured_max_bytes,
        status_code=status_code,
        status_message=status_message,
        session_started_unix_ms=session_started_unix_ms,
        prefix_cache_fingerprints=_fingerprint_snapshot(prefix_cache_fingerprints or []),
    )


def _score_prefix_cache_response(
    *,
    status_code: str,
    status_message: str = "",
    resident_fingerprint_match: bool = False,
    score_tier: str = "unknown",
    session_started_unix_ms: int = 0,
) -> BackendPrefixCacheScore:
    normalized_status = status_code if status_code in _SCORE_PREFIX_CACHE_STATUS_CODES else "error"
    normalized_tier = score_tier if score_tier in _SCORE_PREFIX_CACHE_TIERS else "unknown"

    if normalized_status != "ok":
        resident_fingerprint_match = False

    return BackendPrefixCacheScore(
        status_code=normalized_status,
        status_message=status_message,
        resident_fingerprint_match=resident_fingerprint_match,
        score_tier=normalized_tier,
        session_started_unix_ms=_status_uint64(session_started_unix_ms),
    )


def valid_cache_affinity_fingerprint(fingerprint: Any) -> bool:
    return isinstance(fingerprint, str) and _FINGERPRINT_RE.fullmatch(fingerprint) is not None


def _normalize_fingerprint_buffer_size(value: Any) -> int:
    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 1 <= value <= _MAX_FINGERPRINT_BUFFER_SIZE
    ):
        return value
    return _DEFAULT_FINGERPRINT_BUFFER_SIZE


def _fingerprint_buffer_size_from_config(config: Any | None) -> int:
    return _normalize_fingerprint_buffer_size(
        getattr(config, "max_fingerprint_buffer_size", _DEFAULT_FINGERPRINT_BUFFER_SIZE)
    )


def _append_fingerprint(buffer: list[str], fingerprint: str, capacity: int) -> None:
    if fingerprint in buffer:
        return

    while len(buffer) >= capacity:
        del buffer[0]
    buffer.append(fingerprint)


def _fingerprint_snapshot(fingerprints: Any) -> list[str]:
    if not isinstance(fingerprints, list):
        return []

    snapshot: list[str] = []
    for fingerprint in fingerprints:
        if valid_cache_affinity_fingerprint(fingerprint):
            snapshot.append(fingerprint)
            if len(snapshot) >= _MAX_FINGERPRINT_BUFFER_SIZE:
                break
    return snapshot


def _status_uint32(value: Any) -> int:
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= _UINT32_MAX:
        return value
    return 0


def _status_uint64(value: Any) -> int:
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= _UINT64_MAX:
        return value
    return 0


def _normalize_prefix_cache_stats(stats: Any) -> _NormalizedPrefixCacheStats | None:
    if isinstance(stats, dict):
        implementation = stats.get("implementation")
        entry_count = stats.get("entry_count")
        total_bytes = stats.get("total_bytes")
        hits = stats.get("hits")
        misses = stats.get("misses")
        failures = stats.get("failures")
        stores = stats.get("stores")
        evictions = stats.get("evictions")
    else:
        implementation = getattr(stats, "implementation", None)
        entry_count = getattr(stats, "entry_count", None)
        total_bytes = getattr(stats, "total_bytes", None)
        hits = getattr(stats, "hits", None)
        misses = getattr(stats, "misses", None)
        failures = getattr(stats, "failures", None)
        stores = getattr(stats, "stores", None)
        evictions = getattr(stats, "evictions", None)

    if not isinstance(implementation, str) or implementation == "":
        return None

    normalized = _NormalizedPrefixCacheStats(
        implementation=implementation,
        entry_count=_status_uint32(entry_count),
        total_bytes=_status_uint64(total_bytes),
        hits=_status_uint64(hits),
        misses=_status_uint64(misses),
        failures=_status_uint64(failures),
        stores=_status_uint64(stores),
        evictions=_status_uint64(evictions),
    )

    required_fields = (
        ("entry_count", entry_count),
        ("total_bytes", total_bytes),
        ("hits", hits),
        ("misses", misses),
        ("failures", failures),
        ("stores", stores),
        ("evictions", evictions),
    )

    for field_name, raw_value in required_fields:
        is_uint32 = field_name == "entry_count"
        validated = _status_uint32(raw_value) if is_uint32 else _status_uint64(raw_value)
        if raw_value != validated:
            return None

    return normalized


def build_backend(
    name: str,
    *,
    prefix_cache_config: Any | None = None,
    generation_config: Any | None = None,
    memory_budget_config: Any | None = None,
) -> Backend:
    if name == "stub":
        mode = (
            getattr(generation_config, "mode", "stream")
            if generation_config is not None
            else "stream"
        )
        if mode == "batch":
            raise BackendError(
                "unsupported_backend_config",
                "backend=stub does not support generation_mode=batch",
            )
        return StubBackend(
            max_fingerprint_buffer_size=_fingerprint_buffer_size_from_config(prefix_cache_config)
        )

    if name == "mlx":
        return MLXBackend(
            prefix_cache_config=prefix_cache_config,
            generation_config=generation_config,
            memory_budget_config=memory_budget_config,
        )

    raise BackendError("unsupported_backend", f"unsupported backend: {name}")


def decode_metadata(metadata_json: bytes | str | None) -> dict[str, Any]:
    if metadata_json in (None, b"", ""):
        return {}

    try:
        if isinstance(metadata_json, bytes):
            payload = metadata_json.decode("utf-8")
        else:
            payload = metadata_json

        decoded = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return {}

    return decoded if isinstance(decoded, dict) else {}


def safe_int(value: Any, default: int = 0) -> int:
    """Convert *value* to int, returning *default* on failure."""
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def cancelled_event() -> dict[str, Any]:
    return {
        "kind": "failed",
        "code": "cancelled",
        "message": "request cancelled",
        "retryable": False,
    }
