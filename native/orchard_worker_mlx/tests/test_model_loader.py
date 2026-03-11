"""Unit tests for model_loader.py: manifest parsing, session lifecycle."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from orchard_worker_mlx.model_loader import (
    BundleManifest,
    ChatTemplateSpec,
    LoadedModelSession,
    MLXDeps,
    ModelLoaderError,
    RuntimeRequirementsSpec,
    TokenizerSpec,
    load_manifest,
    load_session,
    parse_manifest_json,
    unload_session,
)

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
) -> MLXDeps:
    fake_model = MagicMock(name="FakeModel")
    fake_tokenizer = MagicMock(name="FakeTokenizer")

    def _load_model(model_path: str, **kwargs: Any) -> tuple[Any, Any]:
        if load_model_side_effect is not None:
            raise load_model_side_effect
        return (fake_model, {})

    def _load_tokenizer(tokenizer_path: Any) -> Any:
        if load_tokenizer_side_effect is not None:
            raise load_tokenizer_side_effect
        return fake_tokenizer

    return MLXDeps(
        load_model=_load_model,
        load_tokenizer=_load_tokenizer,
        eval_fn=MagicMock(name="eval_fn"),
        clear_cache=MagicMock(name="clear_cache"),
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
    assert session.decode_cancel_stride == 1
    assert session.prefix_cache is None

    # Verify deps were called correctly.
    deps.eval_fn.assert_called_once()
    deps.clear_cache.assert_called_once()


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
