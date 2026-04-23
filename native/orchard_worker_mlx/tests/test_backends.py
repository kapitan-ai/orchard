"""Unit tests for backends.py: protocol, single-flight, and parsing helpers."""

from __future__ import annotations

import threading
from dataclasses import replace
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.backends import (
    Backend,
    BackendError,
    BackendHealth,
    MLXBackend,
    StubBackend,
    build_backend,
    decode_metadata,
    safe_int,
)
from orchard_worker_mlx.model_loader import (
    GenerationRuntimeConfig,
    MemoryBudgetConfig,
    MLXEnvironmentHealth,
    PrefixCacheLoadConfig,
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


def test_build_backend_mlx_accepts_generation_and_memory_config() -> None:
    generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)
    memory_budget_config = MemoryBudgetConfig(mode="observe", utilization=0.75)

    backend = build_backend(
        "mlx",
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )

    assert isinstance(backend, Backend)


def test_build_backend_stub_rejects_batch_mode() -> None:
    with pytest.raises(BackendError) as exc_info:
        build_backend(
            "stub",
            generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        )

    assert exc_info.value.code == "unsupported_backend_config"


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


def test_mlx_backend_batch_config_allows_concurrency_up_to_limit() -> None:
    session = _make_fake_session(model_id="m", version="v", bundle_path="/fake/path")
    session.generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)

    class FakeBatchRuntime:
        def __init__(self, _session) -> None:
            self._deps = MagicMock(name="batch_deps")

        def generation_deps(self):
            return self._deps

        def close(self) -> None:
            return None

    backend = MLXBackend(
        session_loader=lambda **_kwargs: session,
        session_unloader=lambda _session: None,
        generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        batch_runtime_factory=lambda loaded_session: FakeBatchRuntime(loaded_session),
    )

    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    backend.start_generation()
    backend.start_generation()

    with pytest.raises(BackendError) as exc_info:
        backend.start_generation()

    assert exc_info.value.code == "worker_busy"


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
    assert decode_metadata(b"[1, 2, 3]") == {}
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


def _fingerprint(seed: int) -> str:
    return f"hmac-sha256:{seed:064x}"


def _make_mlx_backend(
    *,
    loader_session=None,
    loader_error=None,
    unloader_calls=None,
    prefix_cache_config=None,
):
    """Create an MLXBackend with injected fake loader/unloader."""
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

    return MLXBackend(
        session_loader=fake_loader,
        session_unloader=fake_unloader,
        prefix_cache_config=prefix_cache_config,
    )


def test_mlx_backend_initial_status_unloaded() -> None:
    backend = _make_mlx_backend()
    status = backend.status()
    assert status["loaded"] is False
    assert status["active_request_count"] == 0


def test_mlx_backend_load_success() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    session = _make_fake_session()
    session.memory_budget_status = MemoryBudgetStatus(
        mode="observe",
        budget_available=True,
        headroom_available=True,
        status_code="ok",
        max_recommended_working_set_size_bytes=8_000_000_000,
        utilization=0.75,
        target_working_set_bytes=6_000_000_000,
        overhead_bytes=268_435_456,
        resident_memory_bytes=2_048_000,
        estimated_headroom_bytes=5_731_516_544,
        kv_cache_bytes_per_token=16_384,
        prefill_workspace_bytes_per_token=2_048,
    )
    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    status = backend.status()
    assert status["loaded"] is True
    assert status["active_request_count"] == 0
    assert status["memory_budget"]["status_code"] == "ok"
    assert status["memory_budget"]["estimated_headroom_bytes"] == 5_731_516_544
    assert status["memory_budget"]["prefill_workspace_bytes_per_token"] == 2_048


def test_mlx_backend_status_reflects_request_time_prefill_updates() -> None:
    from orchard_worker_mlx.model_loader import MemoryBudgetStatus

    session = _make_fake_session()
    session.memory_budget_status = MemoryBudgetStatus(
        mode="observe",
        budget_available=True,
        headroom_available=True,
        status_code="ok",
        max_recommended_working_set_size_bytes=8_000_000_000,
        utilization=0.75,
        target_working_set_bytes=6_000_000_000,
        overhead_bytes=268_435_456,
        resident_memory_bytes=2_048_000,
        estimated_headroom_bytes=5_731_516_544,
        kv_cache_bytes_per_token=16_384,
        prefill_workspace_bytes_per_token=0,
    )
    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    session.memory_budget_status = replace(
        session.memory_budget_status,
        prefill_workspace_bytes_per_token=512,
    )

    status = backend.status()
    assert status["memory_budget"]["prefill_workspace_bytes_per_token"] == 512


def test_mlx_backend_prefix_cache_status_unavailable_without_session() -> None:
    backend = _make_mlx_backend()

    status = backend.prefix_cache_status()

    assert status["status_code"] == "unavailable"
    assert status["enabled"] is True


def test_mlx_backend_prefix_cache_status_unavailable_when_cache_none() -> None:
    session = _make_fake_session()
    session.prefix_cache = None
    session.session_started_unix_ms = 1234

    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    status = backend.prefix_cache_status()

    assert status["status_code"] == "unavailable"
    assert status["enabled"] is True
    assert status["session_started_unix_ms"] == 1234


def test_mlx_backend_prefix_cache_status_error_on_stats_exception() -> None:
    session = _make_fake_session()
    session.prefix_cache = MagicMock()
    session.prefix_cache.stats.side_effect = RuntimeError("boom")
    session.session_started_unix_ms = 222

    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    status = backend.prefix_cache_status()

    assert status["status_code"] == "error"
    assert status["enabled"] is True
    assert status["session_started_unix_ms"] == 222


def test_mlx_backend_prefix_cache_status_invalid_on_malformed_stats() -> None:
    session = _make_fake_session()
    session.prefix_cache = MagicMock()
    session.prefix_cache.stats.return_value = {"implementation": "kv", "entry_count": "bad"}
    session.session_started_unix_ms = 333

    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    status = backend.prefix_cache_status()

    assert status["status_code"] == "invalid_status"
    assert status["enabled"] is True


def test_mlx_backend_prefix_cache_status_ok() -> None:
    session = _make_fake_session()
    session.prefix_cache = MagicMock()
    session.prefix_cache.stats.return_value = {
        "implementation": "trie",
        "entry_count": 3,
        "total_bytes": 2048,
        "hits": 4,
        "misses": 1,
        "failures": 0,
        "stores": 5,
        "evictions": 2,
    }
    session.session_started_unix_ms = 444

    backend = _make_mlx_backend(loader_session=session)
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    status = backend.prefix_cache_status()

    assert status["status_code"] == "ok"
    assert status["enabled"] is True
    assert status["implementation"] == "trie"
    assert status["entry_count"] == 3
    assert status["stores"] == 5
    assert status["session_started_unix_ms"] == 444


def test_mlx_backend_records_valid_fingerprint() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    fingerprint = _fingerprint(1)
    backend.record_fingerprint(fingerprint)

    assert backend.get_fingerprints() == [fingerprint]
    assert backend.prefix_cache_status()["prefix_cache_fingerprints"] == [fingerprint]


def test_mlx_backend_drops_invalid_fingerprint_and_ignores_empty() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    for fingerprint in [
        "",
        "hmac-sha256:" + "A" * 64,
        "hmac-sha256:" + "a" * 63,
        "sha256:" + "a" * 64,
        "hmac-sha256:" + "g" * 64,
    ]:
        backend.record_fingerprint(fingerprint)

    assert backend.get_fingerprints() == []


def test_mlx_backend_fingerprint_buffer_is_fifo_bounded() -> None:
    backend = _make_mlx_backend(
        prefix_cache_config=PrefixCacheLoadConfig(max_fingerprint_buffer_size=2)
    )
    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    fingerprints = [_fingerprint(1), _fingerprint(2), _fingerprint(3)]
    for fingerprint in fingerprints:
        backend.record_fingerprint(fingerprint)

    assert backend.get_fingerprints() == fingerprints[1:]


def test_mlx_backend_unload_clears_fingerprint_buffer() -> None:
    backend = _make_mlx_backend()
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    backend.record_fingerprint(_fingerprint(1))

    backend.unload_model()

    assert backend.get_fingerprints() == []


def test_mlx_backend_load_passes_generation_and_memory_config_to_loader() -> None:
    captured: dict[str, object] = {}

    def fake_loader(**kwargs):
        captured.update(kwargs)
        return _make_fake_session(
            model_id=kwargs["model_id"],
            version=kwargs["version"],
            bundle_path=kwargs["model_path"],
        )

    generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=3)
    memory_budget_config = MemoryBudgetConfig(
        mode="observe",
        utilization=0.75,
        overhead_bytes=268_435_456,
    )

    backend = MLXBackend(
        session_loader=fake_loader,
        session_unloader=lambda _session: None,
        generation_config=generation_config,
        memory_budget_config=memory_budget_config,
    )

    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    assert captured["generation_config"] == generation_config
    assert captured["memory_budget_config"] == memory_budget_config


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


def test_mlx_backend_unload_keeps_loaded_when_batch_runtime_close_fails() -> None:
    session = _make_fake_session(model_id="m", version="v", bundle_path="/fake/path")
    session.generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)
    unload_calls: list[Any] = []

    class FailingBatchRuntime:
        def close(self) -> None:
            raise BackendError("batch_runtime_close_timeout", "stuck batch runtime", True)

        def generation_deps(self):
            raise AssertionError("generation_deps should not be used in unload test")

    backend = MLXBackend(
        session_loader=lambda **_kwargs: session,
        session_unloader=lambda loaded_session: unload_calls.append(loaded_session),
        generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        batch_runtime_factory=lambda _session: FailingBatchRuntime(),
    )

    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    with pytest.raises(BackendError) as exc_info:
        backend.unload_model()

    assert exc_info.value.code == "batch_runtime_close_timeout"
    assert backend.status()["loaded"] is True
    assert unload_calls == []

    backend.start_generation()
    backend.finish_generation()


def test_mlx_backend_rejects_new_lifecycle_operations_while_unload_is_in_progress() -> None:
    session = _make_fake_session(model_id="m", version="v", bundle_path="/fake/path")
    session.generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)
    unload_calls: list[Any] = []

    class BlockingBatchRuntime:
        def __init__(self) -> None:
            self.close_entered = threading.Event()
            self.allow_close = threading.Event()

        def close(self) -> None:
            self.close_entered.set()
            self.allow_close.wait(timeout=5.0)

        def generation_deps(self):
            raise AssertionError("generation_deps should not be used in unload test")

    runtime = BlockingBatchRuntime()
    backend = MLXBackend(
        session_loader=lambda **_kwargs: session,
        session_unloader=lambda loaded_session: unload_calls.append(loaded_session),
        generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        batch_runtime_factory=lambda _session: runtime,
    )

    backend.load_model(model_id="m", version="v", model_path="/fake/path")

    unload_errors: list[Exception] = []

    def run_unload() -> None:
        try:
            backend.unload_model()
        except Exception as exc:  # pragma: no cover - should stay empty
            unload_errors.append(exc)

    thread = threading.Thread(target=run_unload)
    thread.start()
    assert runtime.close_entered.wait(timeout=1.0) is True

    with pytest.raises(BackendError) as start_exc:
        backend.start_generation()
    assert start_exc.value.code == "model_unloading"

    with pytest.raises(BackendError) as load_exc:
        backend.load_model(model_id="m", version="v", model_path="/fake/path")
    assert load_exc.value.code == "model_unloading"

    with pytest.raises(BackendError) as unload_exc:
        backend.unload_model()
    assert unload_exc.value.code == "model_unloading"

    runtime.allow_close.set()
    thread.join(timeout=2.0)

    assert thread.is_alive() is False
    assert unload_errors == []
    assert backend.status()["loaded"] is False
    assert unload_calls == [session]


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


def test_mlx_backend_batch_runtime_failure_fails_load_and_keeps_backend_unloaded() -> None:
    session = _make_fake_session(model_id="m", version="v", bundle_path="/fake/path")
    session.generation_config = GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2)
    unload_calls: list[Any] = []

    backend = MLXBackend(
        session_loader=lambda **_kwargs: session,
        session_unloader=lambda loaded_session: unload_calls.append(loaded_session),
        generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        batch_runtime_factory=lambda _session: (_ for _ in ()).throw(RuntimeError("no batch")),
    )

    with pytest.raises(BackendError) as exc_info:
        backend.load_model(model_id="m", version="v", model_path="/fake/path")

    assert exc_info.value.code == "batch_runtime_unavailable"
    assert backend.status()["loaded"] is False
    assert unload_calls == [session]


def test_mlx_backend_generate_delegates_to_runner() -> None:
    """MLXBackend.generate delegates to the injected generation_runner."""
    captured: list[tuple] = []

    def fake_runner(session, request, cancel_event):
        captured.append((session, request, cancel_event))
        yield {"kind": "output_text_delta", "delta": "hello"}
        yield {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_STOP",
            "usage": {"input_tokens": 2, "output_tokens": 1, "total_tokens": 3},
        }

    backend = MLXBackend(
        session_loader=lambda **kw: _make_fake_session(
            model_id=kw["model_id"], version=kw["version"], bundle_path=kw["model_path"]
        ),
        session_unloader=lambda s: None,
        generation_runner=fake_runner,
    )
    backend.load_model(model_id="m", version="v", model_path="/fake/path")
    backend.start_generation()

    request = MagicMock()
    cancel = threading.Event()

    events = list(backend.generate(request, cancel))
    backend.finish_generation()

    # Runner received session, request, and cancel_event
    assert len(captured) == 1
    assert captured[0][0].manifest.model_id == "m"
    assert captured[0][1] is request
    assert captured[0][2] is cancel

    # Events forwarded unchanged
    assert events[0] == {"kind": "output_text_delta", "delta": "hello"}
    assert events[-1]["kind"] == "completed"


def test_mlx_backend_generate_requires_loaded_session() -> None:
    """MLXBackend.generate raises model_not_loaded when no session is loaded."""
    backend = MLXBackend(
        session_loader=lambda **kw: _make_fake_session(),
        session_unloader=lambda s: None,
        generation_runner=lambda s, r, c: iter([]),
    )
    # Don't load model — generate should fail
    with pytest.raises(BackendError) as exc_info:
        list(backend.generate(MagicMock(), threading.Event()))
    assert exc_info.value.code == "model_not_loaded"


# -- Backend health contract -------------------------------------------------


def test_stub_backend_health_always_ready() -> None:
    """StubBackend always reports healthy."""
    backend = StubBackend()
    health = backend.health()
    assert health == BackendHealth(ready=True, code="", message="")


def test_mlx_backend_health_ready_when_di_seams_injected() -> None:
    """MLXBackend skips real probe when DI seams are injected."""
    backend = MLXBackend(
        session_loader=lambda **kw: _make_fake_session(),
        session_unloader=lambda s: None,
    )
    health = backend.health()
    assert health["ready"] is True
    assert health["code"] == ""
    assert health["message"] == ""


def test_mlx_backend_health_ready_with_explicit_healthy_probe() -> None:
    """MLXBackend uses explicit health_probe when provided."""

    def healthy_probe() -> MLXEnvironmentHealth:
        return MLXEnvironmentHealth(ready=True)

    backend = MLXBackend(health_probe=healthy_probe)
    health = backend.health()
    assert health["ready"] is True


def test_mlx_backend_health_unhealthy_with_explicit_probe() -> None:
    """MLXBackend reports unhealthy when probe returns unhealthy."""

    def unhealthy_probe() -> MLXEnvironmentHealth:
        return MLXEnvironmentHealth(ready=False, code="mlx_backend_unavailable", message="no mlx")

    backend = MLXBackend(health_probe=unhealthy_probe)
    health = backend.health()
    assert health["ready"] is False
    assert health["code"] == "mlx_backend_unavailable"
    assert health["message"] == "no mlx"


def test_mlx_backend_health_probe_exception_becomes_unhealthy() -> None:
    """If health_probe raises, backend reports metal_unavailable."""

    def bad_probe():
        raise RuntimeError("probe crashed")

    backend = MLXBackend(health_probe=bad_probe)
    health = backend.health()
    assert health["ready"] is False
    assert health["code"] == "metal_unavailable"
    assert "probe crashed" in health["message"]


def test_mlx_backend_health_is_cached() -> None:
    """Health probe is called exactly once at construction."""
    call_count = [0]

    def counting_probe():
        call_count[0] += 1
        return MLXEnvironmentHealth(ready=True)

    backend = MLXBackend(health_probe=counting_probe)
    assert call_count[0] == 1

    # Subsequent health() calls do not re-probe.
    backend.health()
    backend.health()
    assert call_count[0] == 1


def test_mlx_backend_health_returns_copy() -> None:
    """Each health() call returns a fresh dict copy."""
    backend = MLXBackend(
        session_loader=lambda **kw: _make_fake_session(),
        session_unloader=lambda s: None,
    )
    h1 = backend.health()
    h2 = backend.health()
    assert h1 == h2
    assert h1 is not h2  # different dict objects


def test_build_backend_stub_health() -> None:
    """build_backend("stub") returns a backend with healthy health."""
    backend = build_backend("stub")
    health = backend.health()
    assert health["ready"] is True


def test_protocol_requires_health() -> None:
    """Backend protocol requires a health() method."""
    assert hasattr(Backend, "health")


def test_protocol_requires_prefix_cache_status() -> None:
    """Backend protocol requires a prefix_cache_status() method."""
    assert hasattr(Backend, "prefix_cache_status")
