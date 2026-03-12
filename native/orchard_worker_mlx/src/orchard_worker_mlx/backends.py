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


@runtime_checkable
class Backend(Protocol):
    """Structural contract that all worker backends must satisfy."""

    def status(self) -> BackendStatus: ...
    def load_model(self, *, model_id: str, version: str, model_path: str) -> None: ...
    def unload_model(self) -> None: ...
    def start_generation(self) -> None: ...
    def finish_generation(self) -> None: ...
    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]: ...


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


def _stub_generate(
    request: Any, cancel_event: threading.Event
) -> Iterator[dict[str, Any]]:
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

    Tasks 1–2.5 delivered contract hardening, real load/unload, and model
    acquisition.  Task 3 wires real MLX inference via an injectable
    ``generation_runner``.
    """

    def __init__(
        self,
        *,
        session_loader: Callable[..., Any] | None = None,
        session_unloader: Callable[..., None] | None = None,
        generation_runner: Callable[..., Iterator[dict[str, Any]]] | None = None,
    ) -> None:
        from orchard_worker_mlx.model_loader import load_session as _load_session
        from orchard_worker_mlx.model_loader import unload_session as _unload_session

        self._session_loader = session_loader or _load_session
        self._session_unloader = session_unloader or _unload_session
        self._generation_runner = generation_runner or _default_generation_runner()
        self._session: Any | None = None
        self._active_request_count = 0
        self._lock = threading.Lock()

    def status(self) -> BackendStatus:
        with self._lock:
            return BackendStatus(
                loaded=self._session is not None,
                active_request_count=self._active_request_count,
            )

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        from orchard_worker_mlx.model_loader import ModelLoaderError

        logger.info("mlx load_model model_id=%s version=%s", model_id, version)
        with self._lock:
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
                    f"a different model is already loaded ({s.manifest.model_id}@{s.manifest.version})",
                )

            try:
                session = self._session_loader(
                    model_id=model_id,
                    version=version,
                    model_path=model_path,
                )
            except ModelLoaderError as exc:
                raise BackendError(exc.code, exc.message, exc.retryable) from exc

            self._session = session
        logger.info("mlx load_model ok model_id=%s version=%s", model_id, version)

    def unload_model(self) -> None:
        logger.info("mlx unload_model")
        with self._lock:
            if self._session is None:
                return
            if self._active_request_count > 0:
                raise BackendError(
                    "model_busy",
                    "cannot unload: active generation in progress",
                )
            session = self._session
            self._session = None

        # Outside lock: best-effort cleanup.
        try:
            self._session_unloader(session)
        except Exception:
            pass
        logger.info("mlx unload_model ok")

    def start_generation(self) -> None:
        with self._lock:
            if self._session is None:
                raise BackendError("model_not_loaded", "model is not loaded")
            if self._active_request_count > 0:
                raise BackendError("worker_busy", "worker already has an active generation")
            self._active_request_count = 1

    def finish_generation(self) -> None:
        with self._lock:
            self._active_request_count = max(0, self._active_request_count - 1)

    def generate(
        self, request: Any, cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
        with self._lock:
            session = self._session
        if session is None:
            raise BackendError("model_not_loaded", "model is not loaded")
        yield from self._generation_runner(session, request, cancel_event)


def _default_generation_runner() -> Callable[..., Iterator[dict[str, Any]]]:
    """Lazily import the real generation runner."""
    from orchard_worker_mlx.generation import generate_events
    return generate_events


def build_backend(name: str) -> Backend:
    if name == "stub":
        return StubBackend()

    if name == "mlx":
        return MLXBackend()

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


def safe_int(value: object, default: int = 0) -> int:
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
