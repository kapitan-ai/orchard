"""Unit tests for backends.py: protocol, single-flight, and parsing helpers."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from orchard_worker_mlx.backends import (
    Backend,
    BackendError,
    MLXBackend,
    StubBackend,
    build_backend,
    decode_metadata,
    safe_int,
)


# -- Backend protocol conformance --------------------------------------------


def test_stub_backend_satisfies_protocol() -> None:
    assert isinstance(StubBackend(), Backend)


def test_mlx_backend_satisfies_protocol() -> None:
    assert isinstance(MLXBackend(), Backend)


def test_build_backend_stub_returns_backend() -> None:
    backend = build_backend("stub")
    assert isinstance(backend, Backend)


def test_build_backend_mlx_returns_backend() -> None:
    backend = build_backend("mlx")
    assert isinstance(backend, Backend)


def test_build_backend_unsupported_raises() -> None:
    with pytest.raises(BackendError, match="unsupported backend"):
        build_backend("unknown")


# -- Single-flight enforcement -----------------------------------------------


def test_start_generation_requires_loaded_model() -> None:
    backend = StubBackend()
    with pytest.raises(BackendError) as exc_info:
        backend.start_generation()
    assert exc_info.value.code == "model_not_loaded"


def test_start_generation_rejects_second_concurrent(tmp_path: Path) -> None:
    backend = StubBackend()
    model_path = tmp_path / "model"
    model_path.mkdir()
    backend.load_model(model_id="m", version="v", model_path=str(model_path))

    backend.start_generation()
    with pytest.raises(BackendError) as exc_info:
        backend.start_generation()
    assert exc_info.value.code == "worker_busy"


def test_finish_generation_allows_next(tmp_path: Path) -> None:
    backend = StubBackend()
    model_path = tmp_path / "model"
    model_path.mkdir()
    backend.load_model(model_id="m", version="v", model_path=str(model_path))

    backend.start_generation()
    backend.finish_generation()
    # Should succeed after finish
    backend.start_generation()
    backend.finish_generation()

    status = backend.status()
    assert status["active_request_count"] == 0


def test_finish_generation_clamps_to_zero() -> None:
    backend = StubBackend()
    backend.finish_generation()  # No-op when count is already 0
    assert backend.status()["active_request_count"] == 0


# -- decode_metadata ---------------------------------------------------------


def test_decode_metadata_valid_json() -> None:
    assert decode_metadata(b'{"key": "value"}') == {"key": "value"}


def test_decode_metadata_valid_string() -> None:
    assert decode_metadata('{"key": "value"}') == {"key": "value"}


def test_decode_metadata_empty_inputs() -> None:
    assert decode_metadata(None) == {}
    assert decode_metadata(b"") == {}
    assert decode_metadata("") == {}


def test_decode_metadata_invalid_json() -> None:
    assert decode_metadata(b"not json") == {}


def test_decode_metadata_non_dict_json() -> None:
    assert decode_metadata(b'[1, 2, 3]') == {}
    assert decode_metadata(b'"just a string"') == {}


def test_decode_metadata_invalid_utf8() -> None:
    """Invalid UTF-8 bytes must not raise — return empty dict."""
    assert decode_metadata(b"\xff\xfe") == {}


# -- safe_int ----------------------------------------------------------------


def test_safe_int_valid() -> None:
    assert safe_int(42) == 42
    assert safe_int("100") == 100
    assert safe_int(0) == 0


def test_safe_int_invalid_string() -> None:
    assert safe_int("not_a_number") == 0
    assert safe_int("not_a_number", 99) == 99


def test_safe_int_none() -> None:
    assert safe_int(None) == 0
    assert safe_int(None, -1) == -1
