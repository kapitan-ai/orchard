"""Model loading, manifest parsing, and session lifecycle for MLX backends."""

from __future__ import annotations

import gc
import json
import logging
import math
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from pathlib import Path
from typing import Any

from orchard_worker_mlx.prefix_cache import (
    KVPrefixCache,
    PrefixCache,
    TriePrefixCache,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Prefix-cache load configuration
# ---------------------------------------------------------------------------

_VALID_PREFIX_CACHE_MODES = frozenset({"disabled", "kv", "trie"})


@dataclass(slots=True, frozen=True)
class PrefixCacheLoadConfig:
    """Process-scoped configuration for prefix-cache selection.

    Carried from CLI -> service -> backend -> loader.  The loader uses
    this together with manifest metadata to decide which cache
    implementation to provision.
    """

    mode: str = "kv"
    max_entries: int = 8
    max_bytes: int = 0

    def __post_init__(self) -> None:
        if self.mode not in _VALID_PREFIX_CACHE_MODES:
            raise ValueError(
                f"mode must be one of {sorted(_VALID_PREFIX_CACHE_MODES)}, got {self.mode!r}"
            )
        if not isinstance(self.max_entries, int) or isinstance(self.max_entries, bool):
            raise ValueError(f"max_entries must be int, got {type(self.max_entries).__name__}")
        if self.max_entries < 1:
            raise ValueError(f"max_entries must be >= 1, got {self.max_entries}")
        if not isinstance(self.max_bytes, int) or isinstance(self.max_bytes, bool):
            raise ValueError(f"max_bytes must be int, got {type(self.max_bytes).__name__}")
        if self.max_bytes < 0:
            raise ValueError(f"max_bytes must be >= 0, got {self.max_bytes}")


DEFAULT_PREFIX_CACHE_LOAD_CONFIG = PrefixCacheLoadConfig()


# ---------------------------------------------------------------------------
# Generation + memory-budget runtime configuration
# ---------------------------------------------------------------------------

_VALID_GENERATION_MODES = frozenset({"stream", "batch"})
_VALID_MEMORY_BUDGET_MODES = frozenset({"disabled", "observe"})


@dataclass(slots=True, frozen=True)
class GenerationRuntimeConfig:
    """Process-scoped generation mode config.

    This is carried from CLI -> service -> backend -> loader/session, but does
    not enable batch behavior until the later Phase 1 implementation task lands.
    """

    mode: str = "stream"
    max_concurrent_generations: int = 1

    def __post_init__(self) -> None:
        if self.mode not in _VALID_GENERATION_MODES:
            raise ValueError(
                f"mode must be one of {sorted(_VALID_GENERATION_MODES)}, got {self.mode!r}"
            )
        if not isinstance(self.max_concurrent_generations, int) or isinstance(
            self.max_concurrent_generations, bool
        ):
            raise ValueError(
                "max_concurrent_generations must be int, got "
                f"{type(self.max_concurrent_generations).__name__}"
            )
        if self.max_concurrent_generations < 1:
            raise ValueError(
                f"max_concurrent_generations must be >= 1, got {self.max_concurrent_generations}"
            )


@dataclass(slots=True, frozen=True)
class MemoryBudgetConfig:
    """Process-scoped memory-budget config.

    This is carried from CLI -> service -> backend -> loader/session. The
    unsupported "enforce" mode is intentionally rejected until memory-budget
    enforcement is implemented.
    """

    mode: str = "observe"
    utilization: float = 0.90
    overhead_bytes: int = 1_073_741_824

    def __post_init__(self) -> None:
        if self.mode not in _VALID_MEMORY_BUDGET_MODES:
            raise ValueError(
                f"mode must be one of {sorted(_VALID_MEMORY_BUDGET_MODES)}, got {self.mode!r}"
            )
        if not isinstance(self.utilization, (int, float)) or isinstance(self.utilization, bool):
            raise ValueError(f"utilization must be numeric, got {type(self.utilization).__name__}")
        utilization = float(self.utilization)
        object.__setattr__(self, "utilization", utilization)
        if not math.isfinite(utilization):
            raise ValueError(f"utilization must be finite, got {utilization}")
        if utilization <= 0.0 or utilization > 1.0:
            raise ValueError(f"utilization must be > 0.0 and <= 1.0, got {utilization}")
        if not isinstance(self.overhead_bytes, int) or isinstance(self.overhead_bytes, bool):
            raise ValueError(
                f"overhead_bytes must be int, got {type(self.overhead_bytes).__name__}"
            )
        if self.overhead_bytes < 0:
            raise ValueError(f"overhead_bytes must be >= 0, got {self.overhead_bytes}")


DEFAULT_GENERATION_RUNTIME_CONFIG = GenerationRuntimeConfig()
DEFAULT_MEMORY_BUDGET_CONFIG = MemoryBudgetConfig()


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
    max_context_tokens: int | None
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

_KNOWN_TOP_LEVEL_KEYS = frozenset(
    {
        "model_id",
        "version",
        "format",
        "artifact_layout",
        "entrypoint",
        "sha256",
        "size_bytes",
        "resident_memory_bytes",
        "kv_cache_bytes_per_token",
        "prefill_workspace_bytes_per_token",
        "max_context_tokens",
        "capabilities",
        "tokenizer",
        "chat_template",
        "runtime_requirements",
    }
)

_KNOWN_TOKENIZER_KEYS = frozenset({"kind", "path"})
_KNOWN_CHAT_TEMPLATE_KEYS = frozenset({"path", "sha256"})
_KNOWN_RUNTIME_REQUIREMENTS_KEYS = frozenset({"adapter", "min_agent_capability"})

_REQUIRED_STRING_FIELDS = (
    "model_id",
    "version",
    "format",
    "artifact_layout",
    "entrypoint",
    "sha256",
)

_OPTIONAL_NON_NEGATIVE_INT_FIELDS = (
    "size_bytes",
    "resident_memory_bytes",
    "kv_cache_bytes_per_token",
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

    # --- max_context_tokens (optional — nil for models without declared context window) ---
    max_ctx = data.get("max_context_tokens")
    if max_ctx is not None and (type(max_ctx) is not int or max_ctx <= 0):
        raise ModelLoaderError(
            "manifest_validation_error",
            f"max_context_tokens must be a positive integer or null, got {max_ctx!r}",
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
        data,
        "runtime_requirements",
        _KNOWN_RUNTIME_REQUIREMENTS_KEYS,
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
            data,
            "chat_template",
            _KNOWN_CHAT_TEMPLATE_KEYS,
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


def _reject_unknown_keys(data: dict[str, Any], known: frozenset[str], context: str) -> None:
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
    """Narrow test seam for mocked MLX loading.

    ``stream_generate`` and ``monotonic`` are used by warmup inference
    during load to derive ``decode_cancel_stride``.  Tests inject fakes
    for deterministic stride computation without real MLX or wall-clock
    timing.

    NOTE: ``stream_generate`` is also injected in
    ``generation.GenerationDeps`` for request-time generation.  The two
    injection points are intentionally separate (different lifecycle).
    Keep them in sync if the upstream API changes.
    """

    load_model: Callable[..., tuple[Any, Any]]  # (model, tokenizer_or_config)
    load_tokenizer: Callable[[str | Path], Any]
    stream_generate: Callable[..., Iterator[Any]]
    eval_fn: Callable[[Any], None]
    clear_cache: Callable[[], None]
    monotonic: Callable[[], float]
    make_prompt_cache: Callable[[Any], Any] | None = None
    can_trim_prompt_cache: Callable[[Any], bool] | None = None
    make_sampler: Callable[..., Any] | None = None


def _import_required_mlx_runtime_modules() -> tuple:
    """Import the mandatory Python modules for MLX worker readiness.

    Returns ``(mx, stream_generate, mlx_lm_load, mlx_lm_load_tokenizer)``.
    Raises ``ImportError`` if any mandatory dependency is missing.

    This helper is the single source of truth for mandatory runtime
    imports.  Both ``_default_mlx_deps()`` (load-time wiring) and
    ``_default_mlx_probe_deps()`` (health probe) call it, so the
    probe cannot drift from what ``load_session()`` actually needs.

    Optional deps (e.g. ``mlx_lm.models.cache``) are NOT included;
    they are handled fail-open in ``_default_mlx_deps()``.
    """
    import mlx.core as mx
    from mlx_lm.generate import stream_generate
    from mlx_lm.tokenizer_utils import load as mlx_lm_load_tokenizer
    from mlx_lm.utils import load_model as mlx_lm_load

    return mx, stream_generate, mlx_lm_load, mlx_lm_load_tokenizer


def _default_mlx_deps() -> MLXDeps:
    """Import real MLX dependencies lazily."""
    try:
        mx, stream_generate, mlx_lm_load, mlx_lm_load_tokenizer = (
            _import_required_mlx_runtime_modules()
        )
    except ImportError as exc:
        raise ModelLoaderError(
            "mlx_backend_unavailable",
            f"MLX dependencies not available: {exc}",
        ) from exc

    # Optional prompt-cache helpers — fail-open if unavailable.
    _make_prompt_cache: Callable[[Any], Any] | None = None
    _can_trim_prompt_cache: Callable[[Any], bool] | None = None
    try:
        from mlx_lm.models.cache import (
            can_trim_prompt_cache as _can_trim,
        )
        from mlx_lm.models.cache import (
            make_prompt_cache as _make,
        )

        _make_prompt_cache = _make
        _can_trim_prompt_cache = _can_trim
    except (ImportError, AttributeError):
        pass

    # Optional sampler factory — fail-open if unavailable.
    _make_sampler: Callable[..., Any] | None = None
    try:
        from mlx_lm.sample_utils import make_sampler as _make_sampler_impl

        _make_sampler = _make_sampler_impl
    except (ImportError, AttributeError):
        pass

    def _load_model(model_path: str | Path, **kwargs: Any) -> tuple[Any, Any]:
        """Wrap mlx_lm.utils.load_model; returns (model, config)."""
        return mlx_lm_load(Path(model_path), **kwargs)

    def _load_tokenizer(tokenizer_path: str | Path) -> Any:
        # mlx_lm.tokenizer_utils.load expects the bundle directory containing
        # tokenizer assets, not the tokenizer.json file path itself.
        return mlx_lm_load_tokenizer(
            Path(tokenizer_path).parent,
            tokenizer_config_extra={"trust_remote_code": False},
        )

    return MLXDeps(
        load_model=_load_model,
        load_tokenizer=_load_tokenizer,
        stream_generate=stream_generate,
        eval_fn=mx.eval,
        clear_cache=mx.clear_cache,  # stable since mlx 0.22; see pyproject.toml floor
        monotonic=time.monotonic,
        make_prompt_cache=_make_prompt_cache,
        can_trim_prompt_cache=_can_trim_prompt_cache,
        make_sampler=_make_sampler,
    )


# ---------------------------------------------------------------------------
# MLX environment probe
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True)
class MLXProbeDeps:
    """Narrow DI seam for MLX environment probing.

    Keeps probe tests hermetic — no real MLX imports when fakes are injected.
    """

    zeros_fn: Callable[[tuple[int, ...]], Any]
    eval_fn: Callable[[Any], None] | None = None
    clear_cache: Callable[[], None] | None = None


@dataclass(slots=True, frozen=True)
class MLXEnvironmentHealth:
    """Immutable, cached result of a one-shot MLX environment probe."""

    ready: bool
    code: str = ""
    message: str = ""


def _default_mlx_probe_deps() -> MLXProbeDeps:
    """Import real MLX dependencies for probing.

    Uses ``_import_required_mlx_runtime_modules()`` to validate all
    mandatory runtime imports (``mlx.core``, ``mlx_lm``, ``transformers``),
    then builds a ``MLXProbeDeps`` from the ``mlx.core`` subset.

    Raises ``ImportError`` if any mandatory dependency is missing.
    """
    mx, _stream_generate, _mlx_lm_load, _AutoTokenizer = _import_required_mlx_runtime_modules()

    return MLXProbeDeps(
        zeros_fn=mx.zeros,
        eval_fn=mx.eval,
        clear_cache=mx.clear_cache,  # stable since mlx 0.22; see pyproject.toml floor
    )


def probe_mlx_environment(*, deps: MLXProbeDeps | None = None) -> MLXEnvironmentHealth:
    """One-shot probe of MLX runtime availability.

    Checks that MLX can be imported and that a tiny tensor can be allocated
    and evaluated.  Returns an immutable health snapshot.  Never raises.
    """
    try:
        if deps is None:
            deps = _default_mlx_probe_deps()
    except ImportError as exc:
        return MLXEnvironmentHealth(
            ready=False,
            code="mlx_backend_unavailable",
            message=f"MLX dependencies not available: {exc}",
        )
    except Exception as exc:
        return MLXEnvironmentHealth(
            ready=False,
            code="mlx_probe_failed",
            message=f"MLX probe setup failed: {exc}",
        )

    try:
        tensor = deps.zeros_fn((1,))
        if deps.eval_fn is not None:
            deps.eval_fn(tensor)
        return MLXEnvironmentHealth(ready=True)
    except Exception as exc:
        return MLXEnvironmentHealth(
            ready=False,
            code="metal_unavailable",
            message=f"MLX tensor allocation failed: {exc}",
        )
    finally:
        if deps.clear_cache is not None:
            try:
                deps.clear_cache()
            except Exception:
                pass


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
    prefill_step_size: int = 2048
    prefix_cache: PrefixCache | None = None
    generation_config: GenerationRuntimeConfig = DEFAULT_GENERATION_RUNTIME_CONFIG
    memory_budget_config: MemoryBudgetConfig = DEFAULT_MEMORY_BUDGET_CONFIG
    tool_calling: dict[str, Any] = dataclass_field(
        default_factory=lambda: {"supported": False, "parser_type": None}
    )


def _tool_calling_metadata(tokenizer: Any) -> dict[str, Any]:
    init_kwargs = getattr(tokenizer, "init_kwargs", {})
    parser_type = init_kwargs.get("tool_parser_type") if isinstance(init_kwargs, dict) else None
    runtime_supported = callable(getattr(tokenizer, "tool_parser", None)) and isinstance(
        getattr(tokenizer, "tool_call_start", None),
        str,
    )
    supported = runtime_supported or (isinstance(parser_type, str) and parser_type != "")
    return {
        "supported": supported,
        "parser_type": parser_type if isinstance(parser_type, str) and parser_type else None,
    }


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


# ---------------------------------------------------------------------------
# Warmup helpers
# ---------------------------------------------------------------------------

# Fixed constants for warmup inference.
_WARMUP_PROMPT = "Warmup"
_WARMUP_MAX_TOKENS = 50
_WARMUP_PREFILL_STEP_SIZE = 2048
_WARMUP_TARGET_CANCEL_INTERVAL_S = 0.05
_WARMUP_MAX_STRIDE = 32


def _run_warmup(
    model: Any,
    tokenizer: Any,
    *,
    deps: MLXDeps,
) -> int:
    """Run warmup inference and derive ``decode_cancel_stride``.

    Returns the computed stride (>= 1).  On any failure returns 1.
    This function is non-fatal: exceptions are caught and result in
    a safe fallback stride.

    NOTE: Elapsed time includes prefill + iterator setup overhead, not just
    decode.  With the trivial warmup prompt (``_WARMUP_PROMPT = "Warmup"``,
    ~1 token), prefill is negligible and the stride approximation is valid.
    This is an intentional conservative bias — if prefill were ever
    significant, the stride would be underestimated (more frequent cancel
    checks), which is safer than the alternative.  The warmup prompt is
    permanently trivial by design (Q1 answer).
    """
    try:
        prompt_ids = _encode_warmup_prompt(tokenizer, _WARMUP_PROMPT)
        if not prompt_ids:
            return 1

        # Build kwargs for stream_generate
        stream_kwargs: dict[str, Any] = {
            "max_tokens": _WARMUP_MAX_TOKENS,
            "prefill_step_size": _WARMUP_PREFILL_STEP_SIZE,
        }

        # Create sampler if available (Phase 2 enhancement)
        if deps.make_sampler is not None:
            try:
                sampler = deps.make_sampler()
                if sampler is not None:
                    stream_kwargs["sampler"] = sampler
            except Exception:
                # Sampler creation failure counts as warmup failure
                _safe_clear_cache(deps.clear_cache)
                return 1

        t0 = deps.monotonic()
        stream = deps.stream_generate(
            model,
            tokenizer,
            prompt_ids,
            **stream_kwargs,
        )

        output_tokens = 0
        try:
            for _response in stream:
                output_tokens += 1
        finally:
            # Best-effort close regardless of how iteration ended.
            close_fn = getattr(stream, "close", None)
            if close_fn is not None:
                try:
                    close_fn()
                except Exception:
                    pass

        elapsed = deps.monotonic() - t0
        stride = _derive_decode_cancel_stride(output_tokens, elapsed)

        # Post-warmup cache cleanup.
        _safe_clear_cache(deps.clear_cache)

        return stride
    except Exception:
        # Warmup is non-fatal.  Fall back to stride=1.
        _safe_clear_cache(deps.clear_cache)
        return 1


def _encode_warmup_prompt(tokenizer: Any, prompt_text: str) -> list[int]:
    """Encode the warmup prompt.  Returns [] on failure."""
    try:
        # WARNING: add_special_tokens must stay False — matches generation.py
        # contract.  See generation.py module docstring.
        return tokenizer.encode(prompt_text, add_special_tokens=False)
    except Exception:
        return []


def _derive_decode_cancel_stride(output_tokens: int, elapsed_s: float) -> int:
    """Compute stride from warmup throughput.

    Returns 1 on degenerate input (no tokens, zero/negative elapsed).
    """
    if output_tokens <= 0 or elapsed_s <= 0:
        return 1
    tokens_per_second = output_tokens / elapsed_s
    stride = int(tokens_per_second * _WARMUP_TARGET_CANCEL_INTERVAL_S)
    # Clamp to [1, MAX_STRIDE].
    return max(1, min(stride, _WARMUP_MAX_STRIDE))


def _safe_clear_cache(clear_cache: Callable[[], None] | None) -> None:
    """Best-effort cache cleanup.  Swallows all exceptions."""
    if clear_cache is not None:
        try:
            clear_cache()
        except Exception:
            pass


def _build_prefix_cache(
    model: Any,
    manifest: BundleManifest,
    *,
    deps: MLXDeps,
    prefix_cache_config: PrefixCacheLoadConfig,
) -> PrefixCache | None:
    """Select and build a prefix-cache implementation.

    Selection is driven by *prefix_cache_config* and model capability:

    - ``mode="disabled"`` → ``None`` immediately.
    - Non-trimmable models → ``None`` (fail-open probe).
    - ``mode="kv"`` → ``KVPrefixCache``.
    - ``mode="trie"`` → ``TriePrefixCache``, with fallback to
      ``KVPrefixCache`` when a byte budget is configured but
      ``manifest.kv_cache_bytes_per_token`` is missing.
    """
    if prefix_cache_config.mode == "disabled":
        return None

    # --- Trimmability probe (unchanged, fail-open) -------------------------
    if deps.make_prompt_cache is None or deps.can_trim_prompt_cache is None:
        return None

    probe_cache = None
    try:
        probe_cache = deps.make_prompt_cache(model)
        trimmable = deps.can_trim_prompt_cache(probe_cache)
    except Exception:
        return None
    finally:
        # Drop the temporary probe cache regardless of outcome.
        probe_cache = None  # noqa: F841  — intentional ref drop
        _safe_clear_cache(deps.clear_cache)
        gc.collect()

    if not trimmable:
        return None

    # --- Implementation selection ------------------------------------------
    raw_bytes_per_token = manifest.kv_cache_bytes_per_token
    # Treat 0 or negative as unavailable (same as None).
    bytes_per_token = (
        raw_bytes_per_token if raw_bytes_per_token and raw_bytes_per_token > 0 else None
    )
    max_entries = prefix_cache_config.max_entries

    if prefix_cache_config.mode == "kv":
        return KVPrefixCache(
            max_entries=max_entries,
            bytes_per_token=bytes_per_token,
        )

    # mode == "trie"
    max_bytes = prefix_cache_config.max_bytes
    if max_bytes > 0 and bytes_per_token is None:
        logger.warning(
            "prefix_cache trie fallback to kv: max_bytes=%d configured but "
            "manifest.kv_cache_bytes_per_token is missing; "
            "byte budget cannot be enforced",
            max_bytes,
        )
        return KVPrefixCache(
            max_entries=max_entries,
            bytes_per_token=None,
        )

    return TriePrefixCache(
        max_entries=max_entries,
        max_bytes=max_bytes,
        bytes_per_token=bytes_per_token,
    )


def load_session(
    *,
    model_id: str,
    version: str,
    model_path: str,
    deps: MLXDeps | None = None,
    prefix_cache_config: PrefixCacheLoadConfig | None = None,
    generation_config: GenerationRuntimeConfig | None = None,
    memory_budget_config: MemoryBudgetConfig | None = None,
) -> LoadedModelSession:
    """Load a model bundle into a ready-to-generate session.

    Raises ``ModelLoaderError`` on failure.  Performs best-effort cleanup of
    partial allocations before re-raising.
    """
    logger.info("load_session start model_id=%s version=%s path=%s", model_id, version, model_path)
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
    logger.info("load_session loading model and tokenizer")
    if deps is None:
        deps = _default_mlx_deps()

    model = None
    tokenizer = None
    model_config = None
    try:
        model, model_config = deps.load_model(
            entrypoint_path,
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
    tool_calling = _tool_calling_metadata(tokenizer)

    # --- warmup inference to derive decode_cancel_stride ---
    # Non-fatal: failure falls back to stride=1.  Warmup consumes part of
    # the existing worker_load_timeout_ms budget enforced by the outer
    # gRPC LoadModel RPC timeout in WorkerRuntimeAdapter.
    logger.info("load_session warmup start")
    decode_cancel_stride = _run_warmup(model, tokenizer, deps=deps)
    logger.info("load_session warmup ok decode_cancel_stride=%d", decode_cancel_stride)

    # Post-warmup cache cleanup (separate from warmup's own cleanup to
    # cover edge cases where warmup returns successfully but left MLX
    # temporaries allocated).
    _safe_clear_cache(deps.clear_cache)

    # --- prefix cache eligibility probe (fail-open) ---
    effective_config = prefix_cache_config or DEFAULT_PREFIX_CACHE_LOAD_CONFIG
    effective_generation_config = generation_config or DEFAULT_GENERATION_RUNTIME_CONFIG
    effective_memory_budget_config = memory_budget_config or DEFAULT_MEMORY_BUDGET_CONFIG
    prefix_cache = _build_prefix_cache(
        model,
        manifest,
        deps=deps,
        prefix_cache_config=effective_config,
    )

    logger.info("load_session ok model_id=%s version=%s", model_id, version)
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
        decode_cancel_stride=decode_cancel_stride,
        prefix_cache=prefix_cache,
        generation_config=effective_generation_config,
        memory_budget_config=effective_memory_budget_config,
        tool_calling=tool_calling,
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

    logger.info("unload_session start")

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
