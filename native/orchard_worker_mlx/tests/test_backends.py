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


# -- MLXBackend session lifecycle --------------------------------------------


def _make_fake_session(
    model_id: str = "test-org/tiny-llm",
    version: str = "mlx-q4-v1",
    bundle_path: str = "/fake/bundles/test-org/tiny-llm/mlx-q4-v1",
):
    """Create a minimal fake LoadedModelSession for backend tests."""
    from unittest.mock import MagicMock
    from orchard_worker_mlx.model_loader import (
        BundleManifest,
        LoadedModelSession,
        RuntimeRequirementsSpec,
        TokenizerSpec,
    )

    manifest = BundleManifest(
        model_id=model_id,
        version=version,
        format="mlx",
        artifact_layout="directory",
        entrypoint="weights/",
        sha256="abcdef" * 10 + "abcdef1234",
        max_context_tokens=4096,
        capabilities=("chat",),
        tokenizer=TokenizerSpec(kind="huggingface_tokenizer_json", path="tokenizer.json"),
        runtime_requirements=RuntimeRequirementsSpec(adapter="mlx_lm", min_agent_capability="mlx"),
    )
    return LoadedModelSession(
        manifest=manifest,
        bundle_path=Path(bundle_path),
        entrypoint_path=Path(bundle_path) / "weights",
        tokenizer_path=Path(bundle_path) / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
    )


def _make_mlx_backend(
    *,
    loader_session=None,
    loader_error=None,
    unloader_calls=None,
):
    """Create an MLXBackend with injected fake loader/unloader."""
    from orchard_worker_mlx.model_loader import ModelLoaderError

    if unloader_calls is None:
        unloader_calls = []

    def fake_loader(**kwargs):
        if loader_error is not None:
            raise loader_error
        return loader_session or _make_fake_session(
            model_id=kwargs["model_id"],
            version=kwargs["version"],
            bundle_path=kwargs["model_path"],
        )

    def fake_unloader(session):
        unloader_calls.append(session)

    return MLXBackend(session_loader=fake_loader, session_unloader=fake_unloader)


def test_mlx_backend_initial_status_unloaded() -> None:
    backend = _make_mlx_backend()
    status = backend.status()
    assert status["loaded"] is False
    assert status["active_request_count"] == 0


def test_mlx_backend_load_success() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    status = backend.status()
    assert status["loaded"] is True
    assert status["active_request_count"] == 0


def test_mlx_backend_same_model_reload_is_idempotent() -> None:
    call_count = [0]
    session = _make_fake_session(model_id="m", version="v", bundle_path="/fake/path")

    def counting_loader(**kwargs):
        call_count[0] += 1
        return session

    backend = MLXBackend(session_loader=counting_loader, session_unloader=lambda s: None)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    assert call_count[0] == 1

    # Same model, same path: should be a no-op.
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    assert call_count[0] == 1  # Loader not called again.


def test_mlx_backend_conflicting_reload_raises() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v1", model_path="/fake/path")

    with pytest.raises(BackendError) as exc_info:
        backend.load_model(model_id="m", version="v2", model_path="/fake/path2")
    assert exc_info.value.code == "model_already_loaded"


def test_mlx_backend_loader_error_surfaces_as_backend_error() -> None:
    from orchard_worker_mlx.model_loader import ModelLoaderError

    backend = _make_mlx_backend(
        loader_error=ModelLoaderError("model_load_failed", "Metal OOM"),
    )
    with pytest.raises(BackendError) as exc_info:
        backend.load_model(model_id="m", version="v", model_path="/fake/path")
    assert exc_info.value.code == "model_load_failed"
    assert "Metal OOM" in exc_info.value.message

    # Backend should remain unloaded after failed load.
    assert backend.status()["loaded"] is False


def test_mlx_backend_unload_clears_state() -> None:
    unloader_calls: list = []
    backend = _make_mlx_backend(unloader_calls=unloader_calls)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    assert backend.status()["loaded"] is True

    backend.unload_model()
    assert backend.status()["loaded"] is False
    assert len(unloader_calls) == 1


def test_mlx_backend_unload_when_not_loaded_is_noop() -> None:
    unloader_calls: list = []
    backend = _make_mlx_backend(unloader_calls=unloader_calls)
    backend.unload_model()  # Should not raise.
    assert len(unloader_calls) == 0


def test_mlx_backend_unload_with_active_generation_raises() -> None:
    unloader_calls: list = []
    backend = _make_mlx_backend(unloader_calls=unloader_calls)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    backend.start_generation()

    # Unload during active generation: should raise.
    with pytest.raises(BackendError) as exc_info:
        backend.unload_model()
    assert exc_info.value.code == "model_busy"
    assert backend.status()["loaded"] is True
    assert len(unloader_calls) == 0

    # After finishing, unload should work.
    backend.finish_generation()
    backend.unload_model()
    assert backend.status()["loaded"] is False
    assert len(unloader_calls) == 1


def test_mlx_backend_start_generation_requires_loaded() -> None:
    backend = _make_mlx_backend()
    with pytest.raises(BackendError) as exc_info:
        backend.start_generation()
    assert exc_info.value.code == "model_not_loaded"


def test_mlx_backend_single_flight() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    backend.start_generation()

    with pytest.raises(BackendError) as exc_info:
        backend.start_generation()
    assert exc_info.value.code == "worker_busy"

    backend.finish_generation()
    # After finish, a new generation should be allowed.
    backend.start_generation()
    backend.finish_generation()


def test_mlx_backend_generate_uses_stub_helper() -> None:
    """MLXBackend.generate still returns deterministic stub events in Task 2."""
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    backend.start_generation()

    import threading
    from unittest.mock import MagicMock

    request = MagicMock()
    request.metadata_json = b''
    request.input_tokens = 3

    events = list(backend.generate(request, threading.Event()))
    backend.finish_generation()

    kinds = [e["kind"] for e in events]
    assert "output_text_delta" in kinds
    assert kinds[-1] == "completed"
