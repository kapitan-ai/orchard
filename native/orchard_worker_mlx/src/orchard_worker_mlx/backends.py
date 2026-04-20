from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, TypedDict, runtime_checkable

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class BackendError(Exception):
    code: str
    message: str
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


class BackendStatus(TypedDict):
    loaded: bool
    active_request_count: int


class BackendHealth(TypedDict):
    ready: bool
    code: str
    message: str


@runtime_checkable
class Backend(Protocol):
    """Structural contract that all worker backends must satisfy."""

    def status(self) -> BackendStatus: ...
    def health(self) -> BackendHealth: ...
    def load_model(self, *, model_id: str, version: str, model_path: str) -> None: ...
    def unload_model(self) -> None: ...
    def start_generation(self) -> None: ...
    def finish_generation(self) -> None: ...
    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]: ...


class StubBackend:
    def __init__(self) -> None:
        self._loaded_model: tuple[str, str, str] | None = None
        self._active_request_count = 0
        self._lock = threading.Lock()

    def status(self) -> BackendStatus:
        with self._lock:
            return BackendStatus(
                loaded=self._loaded_model is not None,
                active_request_count=self._active_request_count,
            )

    def health(self) -> BackendHealth:
        return BackendHealth(ready=True, code="", message="")

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
            return BackendStatus(
                loaded=self._session is not None,
                active_request_count=self._active_request_count,
            )

    def health(self) -> BackendHealth:
        return BackendHealth(
            ready=self._health["ready"],
            code=self._health["code"],
            message=self._health["message"],
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
                    max_concurrent_requests = session.generation_config.max_concurrent_generations
                    logger.info(
                        "mlx batch generation enabled max_concurrent_generations=%d",
                        max_concurrent_requests,
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
        return StubBackend()

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
