from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class BackendError(Exception):
    code: str
    message: str
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


class StubBackend:
    def __init__(self) -> None:
        self._loaded_model: tuple[str, str, str] | None = None
        self._active_request_count = 0
        self._lock = threading.Lock()

    def status(self) -> dict[str, int | bool]:
        with self._lock:
            return {
                "loaded": self._loaded_model is not None,
                "active_request_count": self._active_request_count,
            }

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        if not Path(model_path).exists():
            raise BackendError("model_path_missing", f"model path is missing: {model_path}")

        with self._lock:
            self._loaded_model = (model_id, version, model_path)

    def unload_model(self) -> None:
        with self._lock:
            self._loaded_model = None

    def start_generation(self) -> None:
        with self._lock:
            if self._loaded_model is None:
                raise BackendError("model_not_loaded", "model is not loaded")

            self._active_request_count += 1

    def finish_generation(self) -> None:
        with self._lock:
            self._active_request_count = max(0, self._active_request_count - 1)

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        metadata = decode_metadata(getattr(request, "metadata_json", b""))
        chunks = metadata.get("worker_chunks") or ["mlx ", "ready"]
        delay_ms = int(metadata.get("worker_delay_ms", 0))

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


class MLXBackend(StubBackend):
    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        try:
            __import__("mlx_lm")
        except ImportError as exc:
            raise BackendError(
                "mlx_backend_unavailable",
                "mlx_lm is not available in this environment",
            ) from exc

        super().load_model(model_id=model_id, version=version, model_path=model_path)


def build_backend(name: str) -> StubBackend:
    if name == "stub":
        return StubBackend()

    if name == "mlx":
        return MLXBackend()

    raise BackendError("unsupported_backend", f"unsupported backend: {name}")


def decode_metadata(metadata_json: bytes | str | None) -> dict[str, Any]:
    if metadata_json in (None, b"", ""):
        return {}

    if isinstance(metadata_json, bytes):
        payload = metadata_json.decode("utf-8")
    else:
        payload = metadata_json

    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError:
        return {}

    return decoded if isinstance(decoded, dict) else {}


def cancelled_event() -> dict[str, Any]:
    return {
        "kind": "failed",
        "code": "cancelled",
        "message": "request cancelled",
        "retryable": False,
    }
