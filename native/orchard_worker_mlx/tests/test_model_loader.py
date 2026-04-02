"""Unit tests for model_loader.py: manifest parsing, session lifecycle."""

from __future__ import annotations

import json
import shutil
import sys
import types
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.model_loader import (
    BundleManifest,
    ChatTemplateSpec,
    LoadedModelSession,
    MLXDeps,
    MLXEnvironmentHealth,
    MLXProbeDeps,
    ModelLoaderError,
    RuntimeRequirementsSpec,
    TokenizerSpec,
    _default_mlx_deps,
    _derive_decode_cancel_stride,
    _run_warmup,
    load_manifest,
    load_session,
    parse_manifest_json,
    probe_mlx_environment,
    unload_session,
)
from orchard_worker_mlx.prefix_cache import KVPrefixCache

# ---------------------------------------------------------------------------
# Fixture paths
# ---------------------------------------------------------------------------

# Canonical test bundle from Orchard controller fixtures.
_REPO_ROOT = Path(__file__).resolve().parents[3]  # native/orchard_worker_mlx -> orchard
_FIXTURE_BUNDLE = _REPO_ROOT / "apps" / "orchard_controller" / "test" / "fixtures" / "bundles" / "test-model-bundle"


@pytest.fixture()
def fixture_bundle() -> Path:
    """Path to the canonical test bundle (read-only reference)."""
    assert _FIXTURE_BUNDLE.is_dir(), f"Fixture bundle not found: {_FIXTURE_BUNDLE}"
    return _FIXTURE_BUNDLE


@pytest.fixture()
def writable_bundle(tmp_path: Path) -> Path:
    """Copy the fixture bundle to a writable temp directory."""
    dest = tmp_path / "test-model-bundle"
    shutil.copytree(_FIXTURE_BUNDLE, dest)
    return dest


def _read_fixture_manifest() -> str:
    return (_FIXTURE_BUNDLE / "manifest.json").read_text()


def _read_fixture_manifest_dict() -> dict[str, Any]:
    return json.loads(_read_fixture_manifest())


# ---------------------------------------------------------------------------
# Fake MLXDeps for mocked load/unload
# ---------------------------------------------------------------------------


def _make_fake_deps(
    *,
    load_model_side_effect: Any = None,
    load_tokenizer_side_effect: Any = None,
    model_config: Any = None,
    tokenizer_eos_token_id: Any = None,
    warmup_responses: int = 10,
    warmup_elapsed_s: float = 0.5,
    warmup_stream_error: Exception | None = None,
    warmup_encode_result: list[int] | None = None,
    make_prompt_cache_side_effect: Exception | None = None,
    can_trim_prompt_cache_return: bool = True,
    can_trim_prompt_cache_side_effect: Exception | None = None,
    make_sampler: Any = None,
) -> MLXDeps:
    fake_model = MagicMock(name="FakeModel")
    fake_tokenizer = MagicMock(name="FakeTokenizer")
    # Set up tokenizer EOS attribute for normalization tests.
    if tokenizer_eos_token_id is not None:
        fake_tokenizer.eos_token_id = tokenizer_eos_token_id
    else:
        # Remove the attribute so getattr returns None.
        del fake_tokenizer.eos_token_id

    # Configure tokenizer.encode for warmup.
    if warmup_encode_result is not None:
        fake_tokenizer.encode = MagicMock(return_value=warmup_encode_result)
    else:
        fake_tokenizer.encode = MagicMock(return_value=[1, 2, 3])  # default non-empty

    effective_config = model_config if model_config is not None else {}

    def _load_model(model_path: str, **kwargs: Any) -> tuple[Any, Any]:
        if load_model_side_effect is not None:
            raise load_model_side_effect
        return (fake_model, effective_config)

    def _load_tokenizer(tokenizer_path: Any) -> Any:
        if load_tokenizer_side_effect is not None:
            raise load_tokenizer_side_effect
        return fake_tokenizer

    def _stream_generate(*args: Any, **kwargs: Any) -> Any:
        if warmup_stream_error is not None:
            raise warmup_stream_error
        # Yield fake responses (simple objects with .text and .finish_reason).
        for i in range(warmup_responses):
            resp = MagicMock(name=f"WarmupResponse_{i}")
            resp.text = "x"
            resp.finish_reason = None if i < warmup_responses - 1 else "length"
            yield resp

    # Deterministic timing: returns t0 on first call, t0 + elapsed on second.
    _time_calls: list[float] = []

    def _monotonic() -> float:
        if not _time_calls:
            _time_calls.append(100.0)
            return 100.0
        _time_calls.append(100.0 + warmup_elapsed_s)
        return 100.0 + warmup_elapsed_s

    # Prompt-cache probe helpers for prefix cache eligibility.
    def _make_prompt_cache(model: Any) -> Any:
        if make_prompt_cache_side_effect is not None:
            raise make_prompt_cache_side_effect
        return MagicMock(name="ProbeCache")

    def _can_trim_prompt_cache(cache: Any) -> bool:
        if can_trim_prompt_cache_side_effect is not None:
            raise can_trim_prompt_cache_side_effect
        return can_trim_prompt_cache_return

    return MLXDeps(
        load_model=_load_model,
        load_tokenizer=_load_tokenizer,
        stream_generate=_stream_generate,
        eval_fn=MagicMock(name="eval_fn"),
        clear_cache=MagicMock(name="clear_cache"),
        monotonic=_monotonic,
        make_prompt_cache=_make_prompt_cache,
        can_trim_prompt_cache=_can_trim_prompt_cache,
        make_sampler=make_sampler,
    )


# ===========================================================================
# Manifest parsing: success
# ===========================================================================


def test_parse_manifest_from_fixture(fixture_bundle: Path) -> None:
    manifest = load_manifest(fixture_bundle)
    assert isinstance(manifest, BundleManifest)
    assert manifest.model_id == "test-org/tiny-llm"
    assert manifest.version == "mlx-q4-v1"
    assert manifest.format == "mlx"
    assert manifest.artifact_layout == "directory"
    assert manifest.entrypoint == "weights/"
    assert manifest.max_context_tokens == 4096
    assert manifest.capabilities == ("chat",)
    assert isinstance(manifest.tokenizer, TokenizerSpec)
    assert manifest.tokenizer.kind == "huggingface_tokenizer_json"
    assert manifest.tokenizer.path == "tokenizer.json"
    assert isinstance(manifest.chat_template, ChatTemplateSpec)
    assert manifest.chat_template.path == "chat_template.jinja"
    assert isinstance(manifest.runtime_requirements, RuntimeRequirementsSpec)
    assert manifest.runtime_requirements.adapter == "mlx_lm"
    assert manifest.size_bytes == 1024000
    assert manifest.resident_memory_bytes == 2048000


def test_parse_manifest_json_without_optional_fields() -> None:
    data = _read_fixture_manifest_dict()
    # Remove optional fields.
    del data["chat_template"]
    del data["size_bytes"]
    del data["resident_memory_bytes"]
    del data["kv_cache_bytes_per_token"]
    del data["prefill_workspace_bytes_per_token"]

    manifest = parse_manifest_json(json.dumps(data))
    assert manifest.chat_template is None
    assert manifest.size_bytes is None
    assert manifest.resident_memory_bytes is None


def test_manifest_is_frozen() -> None:
    manifest = parse_manifest_json(_read_fixture_manifest())
    with pytest.raises(AttributeError):
        manifest.model_id = "changed"  # type: ignore[misc]


# ===========================================================================
# Manifest parsing: error cases
# ===========================================================================


def test_manifest_not_found(tmp_path: Path) -> None:
    with pytest.raises(ModelLoaderError) as exc_info:
        load_manifest(tmp_path / "nonexistent")
    assert exc_info.value.code == "manifest_not_found"


def test_manifest_invalid_json() -> None:
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json("not json")
    assert exc_info.value.code == "manifest_decode_error"


def test_manifest_non_object_json() -> None:
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json('"just a string"')
    assert exc_info.value.code == "manifest_decode_error"


def test_manifest_unknown_top_level_key() -> None:
    data = _read_fixture_manifest_dict()
    data["unknown_key"] = "surprise"
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "unknown_key" in exc_info.value.message


def test_manifest_unknown_nested_key() -> None:
    data = _read_fixture_manifest_dict()
    data["tokenizer"]["unknown_nested"] = True
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "unknown_nested" in exc_info.value.message


def test_manifest_missing_required_field() -> None:
    data = _read_fixture_manifest_dict()
    del data["model_id"]
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "model_id" in exc_info.value.message


def test_manifest_empty_string_required_field() -> None:
    data = _read_fixture_manifest_dict()
    data["version"] = ""
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "version" in exc_info.value.message


def test_manifest_bad_max_context_tokens() -> None:
    data = _read_fixture_manifest_dict()
    data["max_context_tokens"] = 0
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "max_context_tokens" in exc_info.value.message


def test_manifest_boolean_max_context_tokens_rejected() -> None:
    """bool is a subclass of int in Python; ensure booleans are rejected."""
    data = _read_fixture_manifest_dict()
    data["max_context_tokens"] = True
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "max_context_tokens" in exc_info.value.message


def test_manifest_boolean_optional_int_rejected() -> None:
    """bool values in optional int fields must be rejected for Elixir parity."""
    data = _read_fixture_manifest_dict()
    data["size_bytes"] = False
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "size_bytes" in exc_info.value.message


def test_manifest_negative_optional_int() -> None:
    data = _read_fixture_manifest_dict()
    data["size_bytes"] = -1
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "size_bytes" in exc_info.value.message


def test_manifest_bad_capabilities() -> None:
    data = _read_fixture_manifest_dict()
    data["capabilities"] = ["chat", ""]
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "capabilities" in exc_info.value.message


def test_manifest_tokenizer_missing_field() -> None:
    data = _read_fixture_manifest_dict()
    del data["tokenizer"]["kind"]
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"
    assert "tokenizer.kind" in exc_info.value.message


def test_manifest_runtime_requirements_missing() -> None:
    data = _read_fixture_manifest_dict()
    del data["runtime_requirements"]
    with pytest.raises(ModelLoaderError) as exc_info:
        parse_manifest_json(json.dumps(data))
    assert exc_info.value.code == "manifest_validation_error"


# ===========================================================================
# Worker-specific format constraints
# ===========================================================================


def test_load_session_rejects_non_mlx_format(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, format="gguf")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "unsupported_model_format"


def test_load_session_rejects_non_directory_layout(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, artifact_layout="single-file")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "unsupported_artifact_layout"


def test_load_session_rejects_non_mlx_lm_adapter(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, runtime_adapter="vllm")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "unsupported_runtime_adapter"


def test_load_session_rejects_non_hf_tokenizer_kind(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, tokenizer_kind="sentencepiece")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "unsupported_tokenizer_kind"


def test_load_session_identity_mismatch(writable_bundle: Path) -> None:
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="wrong-org/wrong-model", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "model_identity_mismatch"


# ===========================================================================
# Path traversal rejection
# ===========================================================================


def test_load_session_rejects_absolute_entrypoint(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, entrypoint="/etc/passwd")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "bundle_path_escape"


def test_load_session_rejects_parent_traversal_entrypoint(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, entrypoint="../../etc/passwd")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "bundle_path_escape"


def test_load_session_rejects_parent_traversal_tokenizer(writable_bundle: Path) -> None:
    _patch_manifest(writable_bundle, tokenizer_path="../../../etc/passwd")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "bundle_path_escape"


# ===========================================================================
# load_session with mocked MLXDeps
# ===========================================================================


def test_load_session_success(writable_bundle: Path) -> None:
    deps = _make_fake_deps()
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert isinstance(session, LoadedModelSession)
    assert session.manifest.model_id == "test-org/tiny-llm"
    assert session.bundle_path == writable_bundle
    assert session.model is not None
    assert session.tokenizer is not None
    # decode_cancel_stride is derived from warmup (no longer always 1).
    assert isinstance(session.decode_cancel_stride, int)
    assert session.decode_cancel_stride >= 1
    assert session.prefill_step_size == 2048
    assert isinstance(session.prefix_cache, KVPrefixCache)

    # Verify deps were called correctly.
    deps.eval_fn.assert_called_once()
    # clear_cache called: 1x after eval, 1x inside warmup, 1x post-warmup
    assert deps.clear_cache.call_count >= 1

    # New Task 3 fields: model_config and eos_token_ids.
    assert session.model_config == {}
    assert session.eos_token_ids == ()


def test_load_session_retains_model_config(writable_bundle: Path) -> None:
    """load_session stores the config returned by deps.load_model."""
    config = {"model_type": "llama", "eos_token_id": 2}
    deps = _make_fake_deps(model_config=config)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.model_config is config


def test_load_session_eos_from_tokenizer(writable_bundle: Path) -> None:
    """EOS from tokenizer takes precedence."""
    deps = _make_fake_deps(tokenizer_eos_token_id=42)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert 42 in session.eos_token_ids


def test_load_session_eos_from_config(writable_bundle: Path) -> None:
    """EOS from model config when tokenizer has none."""
    deps = _make_fake_deps(model_config={"eos_token_id": 128001})
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.eos_token_ids == (128001,)


def test_load_session_eos_merged_and_deduped(writable_bundle: Path) -> None:
    """EOS IDs from tokenizer and config are merged and de-duplicated."""
    deps = _make_fake_deps(
        tokenizer_eos_token_id=2,
        model_config={"eos_token_id": 2, "eos_token_ids": [2, 128001]},
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    # De-duplicated: tokenizer's 2 first, then config's 128001
    assert session.eos_token_ids == (2, 128001)


def test_load_session_eos_invalid_values_ignored(writable_bundle: Path) -> None:
    """Invalid EOS values (booleans, strings) are silently ignored."""
    deps = _make_fake_deps(
        model_config={"eos_token_id": True, "eos_token_ids": ["not_an_int", 7]},
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    # True is a bool — skipped.  "not_an_int" — skipped.  7 is valid.
    assert session.eos_token_ids == (7,)


def test_load_session_tokenizer_receives_resolved_path(writable_bundle: Path) -> None:
    """Lock: load_tokenizer receives the resolved tokenizer file path."""
    captured_paths: list = []

    def capturing_loader(tokenizer_path: Any) -> Any:
        captured_paths.append(str(tokenizer_path))
        return MagicMock(name="FakeTokenizer")

    deps = MLXDeps(
        load_model=lambda model_path, **kw: (MagicMock(), {}),
        load_tokenizer=capturing_loader,
        stream_generate=lambda *a, **kw: iter([]),
        eval_fn=MagicMock(),
        clear_cache=MagicMock(),
        monotonic=lambda: 0.0,
    )
    load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert len(captured_paths) == 1
    assert captured_paths[0].endswith("tokenizer.json")


def test_load_session_model_load_failure(writable_bundle: Path) -> None:
    deps = _make_fake_deps(load_model_side_effect=RuntimeError("Metal OOM"))
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=deps,
        )
    assert exc_info.value.code == "model_load_failed"
    assert "Metal OOM" in exc_info.value.message


def test_load_session_tokenizer_load_failure(writable_bundle: Path) -> None:
    deps = _make_fake_deps(load_tokenizer_side_effect=RuntimeError("bad tokenizer"))
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=deps,
        )
    assert exc_info.value.code == "model_load_failed"
    assert "bad tokenizer" in exc_info.value.message


def test_load_session_missing_model_path() -> None:
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="x", version="v",
            model_path="/nonexistent/path",
            deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "model_path_missing"


def test_load_session_missing_entrypoint(writable_bundle: Path) -> None:
    # Remove the weights directory so entrypoint doesn't exist.
    shutil.rmtree(writable_bundle / "weights")
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "entrypoint_missing"


def test_load_session_missing_tokenizer_file(writable_bundle: Path) -> None:
    (writable_bundle / "tokenizer.json").unlink()
    with pytest.raises(ModelLoaderError) as exc_info:
        load_session(
            model_id="test-org/tiny-llm", version="mlx-q4-v1",
            model_path=str(writable_bundle), deps=_make_fake_deps(),
        )
    assert exc_info.value.code == "tokenizer_missing"


# ===========================================================================
# unload_session
# ===========================================================================


def test_unload_session_clears_references() -> None:
    session = LoadedModelSession(
        manifest=parse_manifest_json(_read_fixture_manifest()),
        bundle_path=_FIXTURE_BUNDLE,
        entrypoint_path=_FIXTURE_BUNDLE / "weights",
        tokenizer_path=_FIXTURE_BUNDLE / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
    )
    clear_cache = MagicMock()
    collect = MagicMock(return_value=0)

    unload_session(session, clear_cache=clear_cache, collect=collect)

    assert session.model is None
    assert session.tokenizer is None
    assert session.model_config is None
    assert session.prefix_cache is None
    clear_cache.assert_called_once()
    collect.assert_called_once()


def test_unload_session_uses_session_clear_cache() -> None:
    """When no explicit clear_cache is passed, session.clear_cache is used."""
    session_cache = MagicMock()
    session = LoadedModelSession(
        manifest=parse_manifest_json(_read_fixture_manifest()),
        bundle_path=_FIXTURE_BUNDLE,
        entrypoint_path=_FIXTURE_BUNDLE / "weights",
        tokenizer_path=_FIXTURE_BUNDLE / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
        clear_cache=session_cache,
    )
    collect = MagicMock(return_value=0)

    unload_session(session, collect=collect)

    assert session.model is None
    assert session.clear_cache is None  # cleared after use
    session_cache.assert_called_once()
    collect.assert_called_once()


def test_unload_session_explicit_clear_cache_overrides_session() -> None:
    """Explicit clear_cache kwarg takes precedence over session.clear_cache."""
    session_cache = MagicMock()
    explicit_cache = MagicMock()
    session = LoadedModelSession(
        manifest=parse_manifest_json(_read_fixture_manifest()),
        bundle_path=_FIXTURE_BUNDLE,
        entrypoint_path=_FIXTURE_BUNDLE / "weights",
        tokenizer_path=_FIXTURE_BUNDLE / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
        clear_cache=session_cache,
    )

    unload_session(session, clear_cache=explicit_cache)

    explicit_cache.assert_called_once()
    session_cache.assert_not_called()


def test_unload_session_none_is_noop() -> None:
    # Should not raise.
    unload_session(None)


def test_unload_session_swallows_exceptions() -> None:
    session = LoadedModelSession(
        manifest=parse_manifest_json(_read_fixture_manifest()),
        bundle_path=_FIXTURE_BUNDLE,
        entrypoint_path=_FIXTURE_BUNDLE / "weights",
        tokenizer_path=_FIXTURE_BUNDLE / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
    )
    unload_session(
        session,
        clear_cache=MagicMock(side_effect=RuntimeError("cache boom")),
        collect=MagicMock(side_effect=RuntimeError("gc boom")),
    )
    # Should not raise; references still cleared.
    assert session.model is None


# ===========================================================================
# Prefix cache eligibility (Phase 2)
# ===========================================================================


def test_load_session_trimmable_model_initializes_prefix_cache(writable_bundle: Path) -> None:
    """Trimmable model → prefix_cache is a KVPrefixCache instance."""
    deps = _make_fake_deps(can_trim_prompt_cache_return=True)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert isinstance(session.prefix_cache, KVPrefixCache)


def test_load_session_non_trimmable_model_disables_prefix_cache(writable_bundle: Path) -> None:
    """Non-trimmable model (SSM/Mamba) → prefix_cache is None, load succeeds."""
    deps = _make_fake_deps(can_trim_prompt_cache_return=False)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.prefix_cache is None
    assert session.model is not None  # load still succeeded


def test_load_session_make_prompt_cache_failure_disables_prefix_cache(writable_bundle: Path) -> None:
    """make_prompt_cache raises → prefix_cache is None, load succeeds."""
    deps = _make_fake_deps(
        make_prompt_cache_side_effect=RuntimeError("probe boom"),
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.prefix_cache is None
    assert session.model is not None


def test_load_session_can_trim_prompt_cache_failure_disables_prefix_cache(writable_bundle: Path) -> None:
    """can_trim_prompt_cache raises → prefix_cache is None, load succeeds."""
    deps = _make_fake_deps(
        can_trim_prompt_cache_side_effect=RuntimeError("trim check boom"),
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.prefix_cache is None
    assert session.model is not None


def test_load_session_missing_prompt_cache_probes_disables_prefix_cache(
    writable_bundle: Path,
) -> None:
    """MLXDeps with make_prompt_cache=None → prefix_cache is None."""
    deps = MLXDeps(
        load_model=lambda model_path, **kw: (MagicMock(), {}),
        load_tokenizer=lambda p: MagicMock(name="tok", **{"encode.return_value": [1, 2, 3]}),
        stream_generate=lambda *a, **kw: iter([]),
        eval_fn=MagicMock(),
        clear_cache=MagicMock(),
        monotonic=lambda: 0.0,
        make_prompt_cache=None,
        can_trim_prompt_cache=None,
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.prefix_cache is None
    assert session.model is not None


def test_unload_session_clears_populated_prefix_cache() -> None:
    """Unloading a session with a live KVPrefixCache sets prefix_cache to None."""
    cache = KVPrefixCache(max_entries=4)
    session = LoadedModelSession(
        manifest=parse_manifest_json(_read_fixture_manifest()),
        bundle_path=_FIXTURE_BUNDLE,
        entrypoint_path=_FIXTURE_BUNDLE / "weights",
        tokenizer_path=_FIXTURE_BUNDLE / "tokenizer.json",
        model=MagicMock(),
        tokenizer=MagicMock(),
        prefix_cache=cache,
    )
    assert session.prefix_cache is cache

    unload_session(session, clear_cache=MagicMock(), collect=MagicMock(return_value=0))

    assert session.prefix_cache is None


# ===========================================================================
# Warmup inference & stride derivation
# ===========================================================================


def test_warmup_success_sets_stride(writable_bundle: Path) -> None:
    """Warmup with 10 tokens in 0.5s → 20 tok/s → stride = floor(20 * 0.05) = 1."""
    deps = _make_fake_deps(warmup_responses=10, warmup_elapsed_s=0.5)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 1


def test_warmup_high_throughput_stride(writable_bundle: Path) -> None:
    """Warmup with 50 tokens in 0.1s → 500 tok/s → stride = floor(500 * 0.05) = 25."""
    deps = _make_fake_deps(warmup_responses=50, warmup_elapsed_s=0.1)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 25


def test_warmup_stride_capped_at_max(writable_bundle: Path) -> None:
    """Stride is capped at 32 even for very high throughput."""
    deps = _make_fake_deps(warmup_responses=50, warmup_elapsed_s=0.01)
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 32


def test_warmup_failure_falls_back_to_stride_1(writable_bundle: Path) -> None:
    """stream_generate error during warmup → stride=1, session still valid."""
    deps = _make_fake_deps(warmup_stream_error=RuntimeError("MLX boom"))
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 1
    assert session.model is not None
    assert session.tokenizer is not None


def test_warmup_empty_encode_falls_back_to_stride_1(writable_bundle: Path) -> None:
    """Empty prompt encoding → stride=1, session still valid."""
    deps = _make_fake_deps(warmup_encode_result=[])
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 1


def test_warmup_zero_decode_tokens_falls_back_to_stride_1(writable_bundle: Path) -> None:
    """Non-empty prompt but zero decode tokens → stride=1.

    Covers the edge case where prompt encodes successfully but
    stream_generate yields an empty iterator (no tokens generated).
    _derive_decode_cancel_stride(0, positive_elapsed) returns 1.
    """
    def empty_stream(*args, **kwargs):
        return iter([])  # yields nothing

    deps = _make_fake_deps()
    # Override stream_generate to return empty iterator.
    deps = MLXDeps(
        load_model=deps.load_model,
        load_tokenizer=deps.load_tokenizer,
        stream_generate=empty_stream,
        eval_fn=deps.eval_fn,
        clear_cache=deps.clear_cache,
        monotonic=deps.monotonic,
    )
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.decode_cancel_stride == 1


def test_warmup_uses_add_special_tokens_false(writable_bundle: Path) -> None:
    """Warmup must encode with add_special_tokens=False."""
    deps = _make_fake_deps()
    load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    # The fake tokenizer's encode is a MagicMock; check the call.
    # load_tokenizer returns the same fake_tokenizer; warmup calls encode.
    # But the tokenizer is created inside _make_fake_deps, so we access it
    # indirectly via the session returned by load_session.
    # Instead, test the warmup helper directly:
    fake_tok = MagicMock(name="tok")
    fake_tok.encode = MagicMock(return_value=[1, 2, 3])
    fake_deps = MLXDeps(
        load_model=lambda *a, **kw: (MagicMock(), {}),
        load_tokenizer=lambda p: fake_tok,
        stream_generate=lambda *a, **kw: iter([]),
        eval_fn=MagicMock(),
        clear_cache=MagicMock(),
        monotonic=lambda: 0.0,
    )
    _run_warmup(MagicMock(), fake_tok, deps=fake_deps)
    fake_tok.encode.assert_called_once_with("Warmup", add_special_tokens=False)


def test_warmup_passes_prefill_step_size(writable_bundle: Path) -> None:
    """Warmup must pass prefill_step_size=2048 to stream_generate."""
    captured_kwargs: list[dict[str, Any]] = []

    def capturing_stream(*args: Any, **kwargs: Any) -> Any:
        captured_kwargs.append(kwargs)
        return iter([])

    fake_tok = MagicMock(name="tok")
    fake_tok.encode = MagicMock(return_value=[1, 2, 3])
    fake_deps = MLXDeps(
        load_model=lambda *a, **kw: (MagicMock(), {}),
        load_tokenizer=lambda p: fake_tok,
        stream_generate=capturing_stream,
        eval_fn=MagicMock(),
        clear_cache=MagicMock(),
        monotonic=lambda: 0.0,
    )
    _run_warmup(MagicMock(), fake_tok, deps=fake_deps)
    assert len(captured_kwargs) == 1
    assert captured_kwargs[0]["prefill_step_size"] == 2048
    assert captured_kwargs[0]["max_tokens"] == 50


def test_warmup_clear_cache_called(writable_bundle: Path) -> None:
    """clear_cache is called after initial load eval AND after warmup."""
    deps = _make_fake_deps(warmup_responses=5, warmup_elapsed_s=0.1)
    load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    # clear_cache called: 1x after eval, 1x inside _run_warmup, 1x post-warmup in load_session
    assert deps.clear_cache.call_count >= 3


# --- Phase 2.2: Warmup sampler enhancement tests ---


def test_warmup_builds_sampler_when_available() -> None:
    """_run_warmup calls deps.make_sampler() when provided."""
    fake_sampler = MagicMock(name="sampler")
    mock_make_sampler = MagicMock(return_value=fake_sampler, name="make_sampler")
    deps = _make_fake_deps(
        warmup_responses=3,
        warmup_elapsed_s=0.1,
        make_sampler=mock_make_sampler,
    )

    model, _ = deps.load_model("/fake/path")
    tokenizer = deps.load_tokenizer("/fake/path")
    _run_warmup(model, tokenizer, deps=deps)

    mock_make_sampler.assert_called_once_with()


def test_warmup_passes_sampler_to_stream_generate() -> None:
    """Created sampler is forwarded to deps.stream_generate()."""
    fake_sampler = MagicMock(name="sampler")
    mock_make_sampler = MagicMock(return_value=fake_sampler)
    captured_kwargs = {}

    def _capturing_stream_generate(*args: Any, **kwargs: Any) -> Any:
        captured_kwargs.update(kwargs)
        # Yield a simple response
        resp = MagicMock()
        resp.text = "x"
        resp.finish_reason = "length"
        yield resp

    deps = _make_fake_deps(
        warmup_responses=1,
        warmup_elapsed_s=0.1,
        make_sampler=mock_make_sampler,
    )
    # Replace stream_generate with capturing version
    deps = MLXDeps(
        load_model=deps.load_model,
        load_tokenizer=deps.load_tokenizer,
        stream_generate=_capturing_stream_generate,
        eval_fn=deps.eval_fn,
        clear_cache=deps.clear_cache,
        monotonic=deps.monotonic,
        make_prompt_cache=deps.make_prompt_cache,
        can_trim_prompt_cache=deps.can_trim_prompt_cache,
        make_sampler=mock_make_sampler,
    )

    model, _ = deps.load_model("/fake/path")
    tokenizer = deps.load_tokenizer("/fake/path")
    _run_warmup(model, tokenizer, deps=deps)

    assert "sampler" in captured_kwargs
    assert captured_kwargs["sampler"] is fake_sampler
    assert captured_kwargs.get("prefill_step_size") == 2048
    assert captured_kwargs.get("max_tokens") == 50


def test_warmup_missing_make_sampler_preserves_existing_behavior() -> None:
    """Missing make_sampler omits sampler kwarg and continues normally."""
    captured_kwargs = {}

    def _capturing_stream_generate(*args: Any, **kwargs: Any) -> Any:
        captured_kwargs.update(kwargs)
        resp = MagicMock()
        resp.text = "x"
        resp.finish_reason = "length"
        yield resp

    deps = _make_fake_deps(
        warmup_responses=1,
        warmup_elapsed_s=0.1,
        make_sampler=None,  # Explicitly None
    )
    deps = MLXDeps(
        load_model=deps.load_model,
        load_tokenizer=deps.load_tokenizer,
        stream_generate=_capturing_stream_generate,
        eval_fn=deps.eval_fn,
        clear_cache=deps.clear_cache,
        monotonic=deps.monotonic,
        make_prompt_cache=deps.make_prompt_cache,
        can_trim_prompt_cache=deps.can_trim_prompt_cache,
        make_sampler=None,
    )

    model, _ = deps.load_model("/fake/path")
    tokenizer = deps.load_tokenizer("/fake/path")
    stride = _run_warmup(model, tokenizer, deps=deps)

    # Sampler should not be in kwargs
    assert "sampler" not in captured_kwargs
    # Warmup should still complete and return a valid stride
    assert stride >= 1


def test_warmup_sampler_failure_falls_back_to_stride_1(writable_bundle: Path) -> None:
    """Sampler construction failure returns stride=1 but load succeeds."""
    mock_make_sampler = MagicMock(side_effect=RuntimeError("sampler boom"))
    deps = _make_fake_deps(
        warmup_responses=10,
        warmup_elapsed_s=0.5,
        make_sampler=mock_make_sampler,
    )

    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )

    # Warmup should have fallen back to stride=1 due to sampler failure
    assert session.decode_cancel_stride == 1
    # But load should still succeed
    assert session.model is not None
    assert session.tokenizer is not None
    # Prefix cache probe should still have run
    assert session.prefix_cache is not None


def test_session_prefill_step_size_default(writable_bundle: Path) -> None:
    """LoadedModelSession.prefill_step_size defaults to 2048."""
    deps = _make_fake_deps()
    session = load_session(
        model_id="test-org/tiny-llm",
        version="mlx-q4-v1",
        model_path=str(writable_bundle),
        deps=deps,
    )
    assert session.prefill_step_size == 2048


# --- stride derivation unit tests ---


def test_derive_stride_normal() -> None:
    # 100 tokens in 1s → 100 tok/s → stride = floor(100 * 0.05) = 5
    assert _derive_decode_cancel_stride(100, 1.0) == 5


def test_derive_stride_zero_tokens() -> None:
    assert _derive_decode_cancel_stride(0, 1.0) == 1


def test_derive_stride_zero_elapsed() -> None:
    assert _derive_decode_cancel_stride(10, 0.0) == 1


def test_derive_stride_negative_elapsed() -> None:
    assert _derive_decode_cancel_stride(10, -1.0) == 1


def test_derive_stride_clamped_to_max_32() -> None:
    # 10000 tokens in 0.01s → 1000000 tok/s → would be 50000 → capped at 32
    assert _derive_decode_cancel_stride(10000, 0.01) == 32


def test_derive_stride_minimum_is_1() -> None:
    # 1 token in 100s → 0.01 tok/s → stride = floor(0.01 * 0.05) = 0 → clamped to 1
    assert _derive_decode_cancel_stride(1, 100.0) == 1


# ===========================================================================
# Helpers
# ===========================================================================


def _patch_manifest(
    bundle: Path,
    *,
    format: str | None = None,
    artifact_layout: str | None = None,
    entrypoint: str | None = None,
    tokenizer_path: str | None = None,
    tokenizer_kind: str | None = None,
    runtime_adapter: str | None = None,
) -> None:
    """Patch specific fields in the bundle's manifest.json."""
    manifest_path = bundle / "manifest.json"
    data = json.loads(manifest_path.read_text())
    if format is not None:
        data["format"] = format
    if artifact_layout is not None:
        data["artifact_layout"] = artifact_layout
    if entrypoint is not None:
        data["entrypoint"] = entrypoint
    if tokenizer_path is not None:
        data["tokenizer"]["path"] = tokenizer_path
    if tokenizer_kind is not None:
        data["tokenizer"]["kind"] = tokenizer_kind
    if runtime_adapter is not None:
        data["runtime_requirements"]["adapter"] = runtime_adapter
    manifest_path.write_text(json.dumps(data))


# ---------------------------------------------------------------------------
# MLX environment probe
# ---------------------------------------------------------------------------


class TestProbeMlxEnvironment:
    """Unit tests for ``probe_mlx_environment()``."""

    def test_healthy_probe(self):
        """Successful probe returns ready=True."""
        deps = MLXProbeDeps(zeros_fn=lambda shape: [0.0] * shape[0])
        result = probe_mlx_environment(deps=deps)
        assert result == MLXEnvironmentHealth(ready=True)
        assert result.code == ""
        assert result.message == ""

    def test_healthy_probe_with_eval(self):
        """Eval function is called when provided."""
        eval_called = []
        deps = MLXProbeDeps(
            zeros_fn=lambda shape: [0.0] * shape[0],
            eval_fn=lambda t: eval_called.append(t),
        )
        result = probe_mlx_environment(deps=deps)
        assert result.ready is True
        assert len(eval_called) == 1

    def test_import_failure_returns_mlx_backend_unavailable(self):
        """When deps is None and import fails, returns mlx_backend_unavailable."""
        # We can't easily force an import failure with deps=None in CI,
        # so test the explicit import-error code path by passing None
        # and mocking _default_mlx_probe_deps to raise ImportError.
        import orchard_worker_mlx.model_loader as ml

        original = ml._default_mlx_probe_deps
        try:
            ml._default_mlx_probe_deps = lambda: (_ for _ in ()).throw(
                ImportError("no mlx")
            )
            result = probe_mlx_environment(deps=None)
            assert result.ready is False
            assert result.code == "mlx_backend_unavailable"
            assert "no mlx" in result.message
        finally:
            ml._default_mlx_probe_deps = original

    def test_allocation_failure_returns_metal_unavailable(self):
        """Tensor allocation failure returns metal_unavailable."""
        def bad_zeros(shape):
            raise RuntimeError("Metal device not found")

        deps = MLXProbeDeps(zeros_fn=bad_zeros)
        result = probe_mlx_environment(deps=deps)
        assert result.ready is False
        assert result.code == "metal_unavailable"
        assert "Metal device not found" in result.message

    def test_eval_failure_returns_metal_unavailable(self):
        """Eval failure returns metal_unavailable."""
        def bad_eval(tensor):
            raise RuntimeError("eval failed")

        deps = MLXProbeDeps(
            zeros_fn=lambda shape: [0.0] * shape[0],
            eval_fn=bad_eval,
        )
        result = probe_mlx_environment(deps=deps)
        assert result.ready is False
        assert result.code == "metal_unavailable"

    def test_clear_cache_called_on_success(self):
        """clear_cache is called after successful probe."""
        cleared = []
        deps = MLXProbeDeps(
            zeros_fn=lambda shape: [0.0] * shape[0],
            clear_cache=lambda: cleared.append(True),
        )
        probe_mlx_environment(deps=deps)
        assert len(cleared) == 1

    def test_clear_cache_called_on_failure(self):
        """clear_cache is called even when probe fails."""
        cleared = []
        deps = MLXProbeDeps(
            zeros_fn=lambda shape: (_ for _ in ()).throw(RuntimeError("fail")),
            clear_cache=lambda: cleared.append(True),
        )
        probe_mlx_environment(deps=deps)
        assert len(cleared) == 1

    def test_clear_cache_exception_swallowed(self):
        """Exceptions in clear_cache are swallowed."""
        deps = MLXProbeDeps(
            zeros_fn=lambda shape: [0.0] * shape[0],
            clear_cache=lambda: (_ for _ in ()).throw(RuntimeError("cache fail")),
        )
        result = probe_mlx_environment(deps=deps)
        assert result.ready is True

    def test_never_raises(self):
        """Probe never raises, always returns MLXEnvironmentHealth."""
        deps = MLXProbeDeps(
            zeros_fn=lambda shape: (_ for _ in ()).throw(RuntimeError("boom")),
            eval_fn=lambda t: (_ for _ in ()).throw(RuntimeError("boom2")),
            clear_cache=lambda: (_ for _ in ()).throw(RuntimeError("boom3")),
        )
        result = probe_mlx_environment(deps=deps)
        assert isinstance(result, MLXEnvironmentHealth)
        assert result.ready is False

    def test_non_import_error_deps_construction_returns_mlx_probe_failed(self):
        """Non-ImportError during deps construction maps to mlx_probe_failed."""
        import orchard_worker_mlx.model_loader as ml

        original = ml._default_mlx_probe_deps
        try:
            ml._default_mlx_probe_deps = lambda: (_ for _ in ()).throw(
                RuntimeError("probe setup boom")
            )
            result = probe_mlx_environment(deps=None)
            assert result.ready is False
            assert result.code == "mlx_probe_failed"
            assert "probe setup boom" in result.message
        finally:
            ml._default_mlx_probe_deps = original

    def test_missing_mlx_lm_returns_mlx_backend_unavailable(self):
        """Missing mlx_lm import surfaces as mlx_backend_unavailable.

        The shared helper _import_required_mlx_runtime_modules validates
        mlx_lm alongside mlx.core, so a missing mlx_lm should cause the
        probe to report unavailable.
        """
        import orchard_worker_mlx.model_loader as ml

        original = ml._import_required_mlx_runtime_modules
        try:
            def _raise_missing_mlx_lm():
                raise ImportError("No module named 'mlx_lm'")

            ml._import_required_mlx_runtime_modules = _raise_missing_mlx_lm
            result = probe_mlx_environment(deps=None)
            assert result.ready is False
            assert result.code == "mlx_backend_unavailable"
            assert "mlx_lm" in result.message
        finally:
            ml._import_required_mlx_runtime_modules = original

    def test_missing_transformers_returns_mlx_backend_unavailable(self):
        """Missing transformers import surfaces as mlx_backend_unavailable."""
        import orchard_worker_mlx.model_loader as ml

        original = ml._import_required_mlx_runtime_modules
        try:
            def _raise_missing_transformers():
                raise ImportError("No module named 'transformers'")

            ml._import_required_mlx_runtime_modules = _raise_missing_transformers
            result = probe_mlx_environment(deps=None)
            assert result.ready is False
            assert result.code == "mlx_backend_unavailable"
            assert "transformers" in result.message
        finally:
            ml._import_required_mlx_runtime_modules = original

    def test_probe_deps_uses_shared_import_helper(self):
        """_default_mlx_probe_deps delegates to _import_required_mlx_runtime_modules.

        Guards against future drift where probe construction reverts to
        importing only mlx.core.
        """
        import orchard_worker_mlx.model_loader as ml

        original = ml._import_required_mlx_runtime_modules
        called = []
        try:
            def _tracking_helper():
                called.append(True)
                raise ImportError("tracking call")

            ml._import_required_mlx_runtime_modules = _tracking_helper
            # _default_mlx_probe_deps should call the shared helper
            try:
                ml._default_mlx_probe_deps()
            except ImportError:
                pass
            assert len(called) == 1, "_default_mlx_probe_deps must use shared import helper"
        finally:
            ml._import_required_mlx_runtime_modules = original


class TestDefaultMlxDepsSamplerWiring:
    """Tests for _default_mlx_deps() optional sampler factory wiring.

    Phase 2.1: Verify make_sampler is wired when available and fail-open
    when unavailable, without affecting other dependency wiring.
    """

    def test_default_mlx_deps_wires_make_sampler_when_available(self, monkeypatch):
        """Sampler factory is wired when mlx_lm.sample_utils.make_sampler exists."""
        import orchard_worker_mlx.model_loader as ml

        # Stub required runtime modules to avoid real MLX imports
        fake_mx = types.SimpleNamespace(
            eval=lambda t: None,
            clear_cache=lambda: None,
        )
        fake_stream_generate = MagicMock(name="stream_generate")
        fake_load_model = MagicMock(name="load_model")
        fake_autotokenizer = MagicMock(name="AutoTokenizer")

        def _fake_import_required():
            return (fake_mx, fake_stream_generate, fake_load_model, fake_autotokenizer)

        monkeypatch.setattr(ml, "_import_required_mlx_runtime_modules", _fake_import_required)

        # Inject fake mlx_lm.sample_utils with make_sampler
        fake_make_sampler = MagicMock(name="make_sampler")
        fake_sample_utils = types.SimpleNamespace(make_sampler=fake_make_sampler)
        sys.modules["mlx_lm"] = types.SimpleNamespace()
        sys.modules["mlx_lm.sample_utils"] = fake_sample_utils

        try:
            deps = _default_mlx_deps()
            assert deps.make_sampler is fake_make_sampler
            # Verify other required deps are still wired
            assert deps.stream_generate is fake_stream_generate
            assert deps.eval_fn is fake_mx.eval
            assert deps.clear_cache is fake_mx.clear_cache
        finally:
            # Cleanup sys.modules
            sys.modules.pop("mlx_lm.sample_utils", None)
            sys.modules.pop("mlx_lm", None)

    def test_default_mlx_deps_sampler_import_failure_is_fail_open(self, monkeypatch):
        """Sampler import failure is non-fatal; make_sampler is None."""
        import orchard_worker_mlx.model_loader as ml

        # Stub required runtime modules
        fake_mx = types.SimpleNamespace(
            eval=lambda t: None,
            clear_cache=lambda: None,
        )
        fake_stream_generate = MagicMock(name="stream_generate")
        fake_load_model = MagicMock(name="load_model")
        fake_autotokenizer = MagicMock(name="AutoTokenizer")

        def _fake_import_required():
            return (fake_mx, fake_stream_generate, fake_load_model, fake_autotokenizer)

        monkeypatch.setattr(ml, "_import_required_mlx_runtime_modules", _fake_import_required)

        # Inject mlx_lm.sample_utils WITHOUT make_sampler attribute
        fake_sample_utils = types.SimpleNamespace()  # no make_sampler
        sys.modules["mlx_lm"] = types.SimpleNamespace()
        sys.modules["mlx_lm.sample_utils"] = fake_sample_utils

        try:
            deps = _default_mlx_deps()
            assert deps.make_sampler is None
            # No exception raised, other deps still work
            assert deps.stream_generate is fake_stream_generate
            assert deps.eval_fn is fake_mx.eval
        finally:
            sys.modules.pop("mlx_lm.sample_utils", None)
            sys.modules.pop("mlx_lm", None)

    def test_default_mlx_deps_sampler_module_missing_is_fail_open(self, monkeypatch):
        """Missing mlx_lm.sample_utils module is non-fatal; make_sampler is None."""
        import orchard_worker_mlx.model_loader as ml

        # Stub required runtime modules
        fake_mx = types.SimpleNamespace(
            eval=lambda t: None,
            clear_cache=lambda: None,
        )
        fake_stream_generate = MagicMock(name="stream_generate")
        fake_load_model = MagicMock(name="load_model")
        fake_autotokenizer = MagicMock(name="AutoTokenizer")

        def _fake_import_required():
            return (fake_mx, fake_stream_generate, fake_load_model, fake_autotokenizer)

        monkeypatch.setattr(ml, "_import_required_mlx_runtime_modules", _fake_import_required)

        # Inject mlx_lm parent module but make sample_utils raise ImportError on access
        # This simulates the case where mlx_lm exists but sample_utils submodule is missing
        class FakeMlxLm(types.SimpleNamespace):
            def __getattr__(self, name):
                if name == "sample_utils":
                    raise ImportError(f"No module named 'mlx_lm.{name}'")
                return super().__getattr__(name)

        sys.modules["mlx_lm"] = FakeMlxLm()
        # Ensure submodule is not cached
        sys.modules.pop("mlx_lm.sample_utils", None)

        try:
            deps = _default_mlx_deps()
            assert deps.make_sampler is None
            # Other deps still functional
            assert deps.stream_generate is fake_stream_generate
        finally:
            sys.modules.pop("mlx_lm", None)
