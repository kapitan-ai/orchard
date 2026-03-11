"""Model loading, manifest parsing, and session lifecycle for MLX backends."""

from __future__ import annotations

import gc
import json
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class ModelLoaderError(Exception):
    code: str
    message: str
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


# ---------------------------------------------------------------------------
# Manifest dataclasses
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class TokenizerSpec:
    kind: str
    path: str


@dataclass(slots=True, frozen=True)
class ChatTemplateSpec:
    path: str
    sha256: str


@dataclass(slots=True, frozen=True)
class RuntimeRequirementsSpec:
    adapter: str
    min_agent_capability: str


@dataclass(slots=True, frozen=True)
class BundleManifest:
    model_id: str
    version: str
    format: str
    artifact_layout: str
    entrypoint: str
    sha256: str
    max_context_tokens: int
    capabilities: tuple[str, ...]
    tokenizer: TokenizerSpec
    runtime_requirements: RuntimeRequirementsSpec
    chat_template: ChatTemplateSpec | None = None
    size_bytes: int | None = None
    resident_memory_bytes: int | None = None
    kv_cache_bytes_per_token: int | None = None
    prefill_workspace_bytes_per_token: int | None = None


# ---------------------------------------------------------------------------
# Manifest parsing & validation
# ---------------------------------------------------------------------------

_KNOWN_TOP_LEVEL_KEYS = frozenset({
    "model_id", "version", "format", "artifact_layout", "entrypoint", "sha256",
    "size_bytes", "resident_memory_bytes", "kv_cache_bytes_per_token",
    "prefill_workspace_bytes_per_token", "max_context_tokens", "capabilities",
    "tokenizer", "chat_template", "runtime_requirements",
})

_KNOWN_TOKENIZER_KEYS = frozenset({"kind", "path"})
_KNOWN_CHAT_TEMPLATE_KEYS = frozenset({"path", "sha256"})
_KNOWN_RUNTIME_REQUIREMENTS_KEYS = frozenset({"adapter", "min_agent_capability"})

_REQUIRED_STRING_FIELDS = ("model_id", "version", "format", "artifact_layout", "entrypoint", "sha256")

_OPTIONAL_NON_NEGATIVE_INT_FIELDS = (
    "size_bytes", "resident_memory_bytes", "kv_cache_bytes_per_token",
    "prefill_workspace_bytes_per_token",
)


def load_manifest(bundle_path: str | Path) -> BundleManifest:
    """Read and parse ``manifest.json`` from a bundle directory."""
    bundle = Path(bundle_path)
    manifest_path = bundle / "manifest.json"

    if not manifest_path.is_file():
        raise ModelLoaderError(
            "manifest_not_found",
            f"manifest not found: {manifest_path}",
        )

    try:
        payload = manifest_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ModelLoaderError(
            "manifest_read_failed",
            f"failed to read manifest: {exc}",
        ) from exc

    return parse_manifest_json(payload)


def parse_manifest_json(payload: str) -> BundleManifest:
    """Parse a JSON string into a ``BundleManifest``."""
    try:
        data = json.loads(payload)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ModelLoaderError(
            "manifest_decode_error",
            f"invalid manifest JSON: {exc}",
        ) from exc

    if not isinstance(data, dict):
        raise ModelLoaderError(
            "manifest_decode_error",
            "manifest must be a JSON object",
        )

    _reject_unknown_keys(data, _KNOWN_TOP_LEVEL_KEYS, "top-level")

    # --- required string fields ---
    for field in _REQUIRED_STRING_FIELDS:
        _require_non_empty_string(data, field)

    # --- max_context_tokens ---
    max_ctx = data.get("max_context_tokens")
    if type(max_ctx) is not int or max_ctx <= 0:
        raise ModelLoaderError(
            "manifest_validation_error",
            f"max_context_tokens must be a positive integer, got {max_ctx!r}",
        )

    # --- optional non-negative int fields ---
    for field in _OPTIONAL_NON_NEGATIVE_INT_FIELDS:
        val = data.get(field)
        if val is not None:
            if type(val) is not int or val < 0:
                raise ModelLoaderError(
                    "manifest_validation_error",
                    f"{field} must be a non-negative integer or null, got {val!r}",
                )

    # --- capabilities ---
    caps = data.get("capabilities")
    if not isinstance(caps, list) or not all(isinstance(c, str) and c for c in caps):
        raise ModelLoaderError(
            "manifest_validation_error",
            f"capabilities must be a list of non-empty strings, got {caps!r}",
        )

    # --- tokenizer ---
    tokenizer = _parse_nested(
        data, "tokenizer", _KNOWN_TOKENIZER_KEYS, required_fields=("kind", "path")
    )
    tokenizer_spec = TokenizerSpec(kind=tokenizer["kind"], path=tokenizer["path"])

    # --- runtime_requirements ---
    rt_req = _parse_nested(
        data, "runtime_requirements", _KNOWN_RUNTIME_REQUIREMENTS_KEYS,
        required_fields=("adapter", "min_agent_capability"),
    )
    rt_spec = RuntimeRequirementsSpec(
        adapter=rt_req["adapter"],
        min_agent_capability=rt_req["min_agent_capability"],
    )

    # --- chat_template (optional) ---
    chat_template_spec: ChatTemplateSpec | None = None
    if "chat_template" in data:
        ct = _parse_nested(
            data, "chat_template", _KNOWN_CHAT_TEMPLATE_KEYS,
            required_fields=("path", "sha256"),
        )
        chat_template_spec = ChatTemplateSpec(path=ct["path"], sha256=ct["sha256"])

    return BundleManifest(
        model_id=data["model_id"],
        version=data["version"],
        format=data["format"],
        artifact_layout=data["artifact_layout"],
        entrypoint=data["entrypoint"],
        sha256=data["sha256"],
        max_context_tokens=max_ctx,
        capabilities=tuple(caps),
        tokenizer=tokenizer_spec,
        runtime_requirements=rt_spec,
        chat_template=chat_template_spec,
        size_bytes=data.get("size_bytes"),
        resident_memory_bytes=data.get("resident_memory_bytes"),
        kv_cache_bytes_per_token=data.get("kv_cache_bytes_per_token"),
        prefill_workspace_bytes_per_token=data.get("prefill_workspace_bytes_per_token"),
    )


# ---------------------------------------------------------------------------
# Manifest validation helpers
# ---------------------------------------------------------------------------


def _reject_unknown_keys(
    data: dict[str, Any], known: frozenset[str], context: str
) -> None:
    unknown = set(data.keys()) - known
    if unknown:
        raise ModelLoaderError(
            "manifest_validation_error",
            f"unknown {context} keys: {sorted(unknown)}",
        )


def _require_non_empty_string(data: dict[str, Any], field: str) -> None:
    val = data.get(field)
    if not isinstance(val, str) or not val:
        raise ModelLoaderError(
            "manifest_validation_error",
            f"{field} must be a non-empty string, got {val!r}",
        )


def _parse_nested(
    data: dict[str, Any],
    key: str,
    known_keys: frozenset[str],
    required_fields: tuple[str, ...],
) -> dict[str, str]:
    nested = data.get(key)
    if not isinstance(nested, dict):
        raise ModelLoaderError(
            "manifest_validation_error",
            f"{key} must be an object, got {type(nested).__name__}",
        )
    _reject_unknown_keys(nested, known_keys, key)
    for field in required_fields:
        val = nested.get(field)
        if not isinstance(val, str) or not val:
            raise ModelLoaderError(
                "manifest_validation_error",
                f"{key}.{field} must be a non-empty string, got {val!r}",
            )
    return nested


# ---------------------------------------------------------------------------
# MLX dependency injection seam
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class MLXDeps:
    """Narrow test seam for mocked MLX loading."""

    load_model: Callable[..., tuple[Any, Any]]  # (model, tokenizer_or_config)
    load_tokenizer: Callable[[str | Path], Any]
    eval_fn: Callable[[Any], None]
    clear_cache: Callable[[], None]


def _default_mlx_deps() -> MLXDeps:
    """Import real MLX dependencies lazily."""
    try:
        import mlx.core as mx
        from mlx_lm.utils import load as mlx_lm_load
        from transformers import AutoTokenizer
    except ImportError as exc:
        raise ModelLoaderError(
            "mlx_backend_unavailable",
            f"MLX dependencies not available: {exc}",
        ) from exc

    def _load_model(model_path: str, **kwargs: Any) -> tuple[Any, Any]:
        return mlx_lm_load(model_path, **kwargs)

    def _load_tokenizer(tokenizer_path: str | Path) -> Any:
        # from_pretrained expects a directory containing tokenizer files,
        # not a direct file path.  The bundle stores tokenizer.json as a
        # file, so pass the parent directory.
        return AutoTokenizer.from_pretrained(
            str(Path(tokenizer_path).parent), trust_remote_code=False,
        )

    return MLXDeps(
        load_model=_load_model,
        load_tokenizer=_load_tokenizer,
        eval_fn=mx.eval,
        clear_cache=lambda: mx.metal.clear_cache() if hasattr(mx, "metal") else None,
    )


# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class LoadedModelSession:
    """All loaded runtime assets owned by MLXBackend."""

    manifest: BundleManifest
    bundle_path: Path
    entrypoint_path: Path
    tokenizer_path: Path
    model: Any
    tokenizer: Any
    model_config: Any | None = None
    eos_token_ids: tuple[int, ...] = ()
    clear_cache: Callable[[], None] | None = None
    decode_cancel_stride: int = 1
    prefix_cache: Any | None = None


def _normalize_eos_token_ids(tokenizer: Any, model_config: Any) -> tuple[int, ...]:
    """Extract and normalize EOS token IDs from tokenizer and model config.

    Precedence: tokenizer first, model config second.  De-duplicates while
    preserving first-seen order.  Returns empty tuple if no valid IDs found
    (does not fail).
    """
    raw_ids: list[int] = []

    for source in (tokenizer, model_config):
        if source is None:
            continue
        for attr_name in ("eos_token_ids", "eos_token_id"):
            val = None
            if isinstance(source, dict):
                val = source.get(attr_name)
            else:
                val = getattr(source, attr_name, None)
            if val is None:
                continue
            _collect_eos_ids(val, raw_ids)

    # De-duplicate preserving order.
    seen: set[int] = set()
    result: list[int] = []
    for eid in raw_ids:
        if eid not in seen:
            seen.add(eid)
            result.append(eid)
    return tuple(result)


def _collect_eos_ids(val: Any, out: list[int]) -> None:
    """Append valid int EOS IDs from *val* into *out*, skipping booleans."""
    if isinstance(val, bool):
        return
    if isinstance(val, int):
        out.append(val)
        return
    if isinstance(val, str):
        # Strings are iterable but never valid EOS IDs.
        return
    if isinstance(val, set):
        # Sort for deterministic ordering from sets.
        for item in sorted(val):
            _collect_eos_ids(item, out)
        return
    try:
        for item in val:
            _collect_eos_ids(item, out)
    except TypeError:
        pass


def _resolve_bundle_subpath(bundle_root: Path, relative: str, label: str) -> Path:
    """Resolve a bundle-relative path, rejecting escapes and absolutes."""
    if Path(relative).is_absolute():
        raise ModelLoaderError(
            "bundle_path_escape",
            f"{label} must be a relative path, got {relative!r}",
        )

    resolved = (bundle_root / relative).resolve()
    bundle_resolved = bundle_root.resolve()

    if not (resolved == bundle_resolved or str(resolved).startswith(str(bundle_resolved) + "/")):
        raise ModelLoaderError(
            "bundle_path_escape",
            f"{label} escapes bundle root: {relative!r}",
        )

    return resolved


def load_session(
    *,
    model_id: str,
    version: str,
    model_path: str,
    deps: MLXDeps | None = None,
) -> LoadedModelSession:
    """Load a model bundle into a ready-to-generate session.

    Raises ``ModelLoaderError`` on failure.  Performs best-effort cleanup of
    partial allocations before re-raising.
    """
    bundle = Path(model_path)
    if not bundle.is_dir():
        raise ModelLoaderError(
            "model_path_missing",
            f"model path does not exist or is not a directory: {model_path}",
        )

    manifest = load_manifest(bundle)

    # --- identity cross-check ---
    if manifest.model_id != model_id:
        raise ModelLoaderError(
            "model_identity_mismatch",
            f"manifest model_id {manifest.model_id!r} != requested {model_id!r}",
        )
    if manifest.version != version:
        raise ModelLoaderError(
            "model_identity_mismatch",
            f"manifest version {manifest.version!r} != requested {version!r}",
        )

    # --- worker-specific format constraints ---
    if manifest.format != "mlx":
        raise ModelLoaderError(
            "unsupported_model_format",
            f"unsupported format: {manifest.format!r} (expected 'mlx')",
        )
    if manifest.artifact_layout != "directory":
        raise ModelLoaderError(
            "unsupported_artifact_layout",
            f"unsupported artifact layout: {manifest.artifact_layout!r}",
        )
    if manifest.runtime_requirements.adapter != "mlx_lm":
        raise ModelLoaderError(
            "unsupported_runtime_adapter",
            f"unsupported adapter: {manifest.runtime_requirements.adapter!r}",
        )
    if manifest.tokenizer.kind != "huggingface_tokenizer_json":
        raise ModelLoaderError(
            "unsupported_tokenizer_kind",
            f"unsupported tokenizer kind: {manifest.tokenizer.kind!r}",
        )

    # --- resolve bundle-relative paths ---
    entrypoint_path = _resolve_bundle_subpath(bundle, manifest.entrypoint, "entrypoint")
    tokenizer_path = _resolve_bundle_subpath(bundle, manifest.tokenizer.path, "tokenizer.path")

    if not entrypoint_path.exists():
        raise ModelLoaderError(
            "entrypoint_missing",
            f"entrypoint does not exist: {entrypoint_path}",
        )
    if not tokenizer_path.exists():
        raise ModelLoaderError(
            "tokenizer_missing",
            f"tokenizer does not exist: {tokenizer_path}",
        )

    # --- load MLX model and tokenizer ---
    if deps is None:
        deps = _default_mlx_deps()

    model = None
    tokenizer = None
    model_config = None
    try:
        model, model_config = deps.load_model(
            str(entrypoint_path),
            lazy=True,
            strict=False,
        )
        deps.eval_fn(model)
        deps.clear_cache()

        tokenizer = deps.load_tokenizer(tokenizer_path)
    except ModelLoaderError:
        raise
    except Exception as exc:
        # Best-effort cleanup of partial allocations.
        model = None
        tokenizer = None
        try:
            deps.clear_cache()
        except Exception:
            pass
        gc.collect()

        if "mlx_lm" in type(exc).__module__ if hasattr(type(exc), "__module__") else False:
            raise ModelLoaderError(
                "model_load_failed",
                f"MLX model load failed: {exc}",
            ) from exc
        else:
            raise ModelLoaderError(
                "model_load_failed",
                f"model load failed: {exc}",
            ) from exc

    eos_token_ids = _normalize_eos_token_ids(tokenizer, model_config)

    return LoadedModelSession(
        manifest=manifest,
        bundle_path=bundle,
        entrypoint_path=entrypoint_path,
        tokenizer_path=tokenizer_path,
        model=model,
        tokenizer=tokenizer,
        model_config=model_config,
        eos_token_ids=eos_token_ids,
        clear_cache=deps.clear_cache,
        decode_cancel_stride=1,
        prefix_cache=None,
    )


def unload_session(
    session: LoadedModelSession | None,
    *,
    clear_cache: Callable[[], None] | None = None,
    collect: Callable[[], int] = gc.collect,
) -> None:
    """Best-effort cleanup of a loaded model session."""
    if session is None:
        return

    # Use session-stored clear_cache if caller doesn't override.
    effective_clear_cache = clear_cache or session.clear_cache

    # Drop references so GC can reclaim.
    session.model = None
    session.tokenizer = None
    session.model_config = None
    session.prefix_cache = None
    session.clear_cache = None

    try:
        if effective_clear_cache is not None:
            effective_clear_cache()
    except Exception:
        pass

    try:
        collect()
    except Exception:
        pass
