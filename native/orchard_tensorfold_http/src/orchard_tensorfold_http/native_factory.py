"""Lazy native assembly for the exact isolated comparison tuple.

Importing this module does not import MLX or load a model. Native operations are
available only through an explicitly configured, identity-verified load call.
"""

import json
import os
import stat
from collections.abc import Callable
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.model_loader import (
    _reject_model_file_config,
    _resolve_bundle_subpath,
    _tool_calling_metadata,
    load_manifest,
)

from orchard_tensorfold_http.admission import ExperimentProfile, positive_int
from orchard_tensorfold_http.backend import RuntimeAssets
from orchard_tensorfold_http.memory_observation import MemoryObserver
from orchard_tensorfold_http.rendering import bind_chat_template
from orchard_tensorfold_http.tensorfold_driver import (
    DriverBounds,
    TensorFoldDriver,
    required_cache_leases,
)

_TUPLE = {"tensorfold": "0.6.6", "mlx": "0.32.3", "mlx-lm": "0.32.0", "transformers": "5.14.1"}
MIN_CHUNK = 256


class _ThinkingOnProbe:
    """Tokenizer adapter used only to probe the admitted thinking-only template."""

    def __init__(self, tokenizer: Any) -> None:
        self._tokenizer = tokenizer

    def __getattr__(self, name: str) -> Any:
        return getattr(self._tokenizer, name)

    def apply_chat_template(self, messages: Any, **options: Any) -> Any:
        return self._tokenizer.apply_chat_template(
            messages, **{**options, "enable_thinking": True, "thinking_mode": "thinking"}
        )


def _prefill_plan(tokenizer: Any, step: int) -> Any:
    from tensorfold.engine.prefill_plan import PrefillPlan, message_markers

    try:
        openers, assistant = message_markers(_ThinkingOnProbe(tokenizer))
    except Exception as exc:
        raise BackendError(
            "unsupported_model_profile", "message marker probe failed", False
        ) from exc
    if not openers or not assistant:
        raise BackendError("unsupported_model_profile", "message markers are not admitted", False)
    # At step 128, min_chunk == step preserves the old grid; real reply cuts
    # never use a minimum below 256 when the step permits message-aware cuts.
    min_chunk = min(MIN_CHUNK, step)
    if min_chunk < len(assistant):
        raise BackendError(
            "unsupported_model_profile", "prefill step cannot fit assistant marker", False
        )
    return PrefillPlan(step, openers, min_chunk, assistant)


def verify_artifact(root: Path, expected: str, *, max_files: int, max_bytes: int) -> None:
    """Match Orchard.ArtifactBundle's relative-path/content tree digest.

    Bounded inventory and before/after inode/stat observations reject a changing
    or unsupported tree. This does not replace Node acquisition/trust checks.
    """
    positive_int(max_files, "bundle file bound")
    positive_int(max_bytes, "bundle byte bound")

    def identity(info: os.stat_result) -> tuple[int, ...]:
        return (
            info.st_mode,
            info.st_dev,
            info.st_ino,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )

    def inventory() -> list[tuple[str, tuple[int, ...]]]:
        rows: list[tuple[str, tuple[int, ...]]] = []
        size = 0
        pending = [root]
        while pending:
            path = pending.pop()
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                for child in path.iterdir():
                    if 1 + len(rows) + len(pending) >= max_files:
                        raise ValueError("artifact inventory exceeds configured bound")
                    pending.append(child)
            elif stat.S_ISREG(info.st_mode):
                size += info.st_size
            else:
                raise ValueError("artifact contains unsupported filesystem entry")
            if size > max_bytes or len(rows) >= max_files:
                raise ValueError("artifact inventory exceeds configured bound")
            rows.append((relative, identity(info)))
        return sorted(rows)

    before = inventory()
    digest = sha256()
    read_total = 0
    for relative, info in before:
        if not stat.S_ISREG(info[0]):
            continue
        digest.update(relative.encode("utf-8"))
        descriptor = os.open(root / relative, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as stream:
            if identity(os.fstat(stream.fileno())) != info:
                raise ValueError("artifact file identity changed before verification")
            remaining = info[3]
            while chunk := stream.read(min(64 * 1024, remaining + 1)):
                read_total += len(chunk)
                if len(chunk) > remaining or read_total > max_bytes:
                    raise ValueError("artifact read exceeds configured bound")
                digest.update(chunk)
                remaining -= len(chunk)
            if remaining or identity(os.fstat(stream.fileno())) != info:
                raise ValueError("artifact file changed during verification")
    if before != inventory() or digest.hexdigest() != expected:
        raise ValueError("artifact identity is missing or changed")


def _validate_custody_bounds(bounds: DriverBounds) -> None:
    # The backend sends only the history boundary, so startup checks the peak
    # without extra boundaries; admission refuses a request that needs more.
    # The last copy needs its own and a transient reservation beside the
    # working reservation and every other lease.
    if bounds.max_cache_leases < required_cache_leases(bounds.checkpoint_slots):
        raise ValueError("cache lease bound is below the scheduler's per-request copy peak")
    working = bounds.working_bytes
    needed = working + bounds.workspace_bytes + (bounds.max_cache_leases + 1) * working
    if bounds.total_budget_bytes < needed:
        raise ValueError("custody budget cannot hold the cache lease bound")


class NativeFactory:
    """No alternate loader/model/template is selected from a request field."""

    def __init__(
        self,
        *,
        bounds: DriverBounds,
        model_path: Path,
        max_bundle_files: int,
        max_bundle_bytes: int,
        prefill_step: int,
    ):
        _validate_custody_bounds(bounds)
        self.bounds, self.model_path = bounds, model_path.absolute()
        self.max_bundle_files = positive_int(max_bundle_files, "bundle file bound")
        self.max_bundle_bytes = positive_int(max_bundle_bytes, "bundle byte bound")
        self.prefill_step = positive_int(prefill_step, "prefill step")

    def __call__(
        self, path: str, profile: ExperimentProfile, quarantine: Callable[[], None]
    ) -> RuntimeAssets:
        if Path(path).absolute() != self.model_path:
            raise BackendError(
                "model_identity_mismatch", "model path is outside frozen profile", False
            )
        if any(version(name) != value for name, value in _TUPLE.items()):
            raise BackendError("unsupported_runtime_tuple", "runtime tuple is not frozen", False)
        if (
            any(
                getattr(profile, key) != getattr(self.bounds, key)
                for key in (
                    "max_input_tokens",
                    "max_output_tokens",
                    "max_context_tokens",
                    "vocabulary_size",
                )
            )
            or profile.max_request_seconds > self.bounds.request_seconds
        ):
            raise BackendError(
                "unsupported_runtime_config", "profile and driver bounds disagree", False
            )
        verify_artifact(
            self.model_path,
            profile.artifact_digest,
            max_files=self.max_bundle_files,
            max_bytes=self.max_bundle_bytes,
        )
        manifest = load_manifest(self.model_path)
        if (
            (
                manifest.model_id,
                manifest.version,
                manifest.format,
                manifest.artifact_layout,
                manifest.runtime_requirements.adapter,
                manifest.tokenizer.kind,
            )
            != (
                profile.model_id,
                profile.version,
                "mlx",
                "directory",
                "mlx_lm",
                "huggingface_tokenizer_json",
            )
            or manifest.chat_template is None
            or manifest.chat_template.sha256 != profile.template_digest
        ):
            raise BackendError("model_identity_mismatch", "bundle is outside frozen profile", False)
        entrypoint = _resolve_bundle_subpath(self.model_path, manifest.entrypoint, "entrypoint")
        tokenizer_path = _resolve_bundle_subpath(
            self.model_path, manifest.tokenizer.path, "tokenizer"
        )
        # Orchard declares the tokenizer JSON file. TensorFold's frozen family
        # loader loads the tokenizer from its model entrypoint directory.
        # Admit only that exact layout; do not verify one tokenizer and run another.
        if not tokenizer_path.is_file() or tokenizer_path.parent != entrypoint:
            raise BackendError(
                "unsupported_model_profile", "tokenizer layout is not admitted", False
            )
        template = _resolve_bundle_subpath(self.model_path, manifest.chat_template.path, "template")
        config_path = tokenizer_path.parent / "tokenizer_config.json"
        render = bind_chat_template(
            template,
            config_path,
            template_digest=profile.template_digest,
            config_digest=profile.tokenizer_config_digest,
        )
        _reject_model_file_config(entrypoint)
        config = json.loads((entrypoint / "config.json").read_bytes())
        tokenizer_config = json.loads(config_path.read_bytes())
        if (
            config.get("model_type") != "qwen3_5"
            or config.get("auto_map")
            or tokenizer_config.get("auto_map")
            or tokenizer_config.get("tool_parser_type") != "qwen3_coder"
        ):
            raise BackendError("unsupported_model_profile", "model/config is not admitted", False)
        return self._assemble(entrypoint, profile, render, quarantine)

    def _assemble(
        self,
        entrypoint: Path,
        profile: ExperimentProfile,
        render: Callable[..., str],
        quarantine: Callable[[], None],
    ) -> RuntimeAssets:
        import mlx.core as mx
        from mlx_lm.models.cache import ArraysCache, KVCache
        from tensorfold.engine.alternating_kv import AlternatingKVCache
        from tensorfold.engine.exact_sampling import Sampling, seed_for
        from tensorfold.engine.lane_engine import LaneEngine
        from tensorfold.families.qwen3_5 import load
        from tensorfold.server.memory_budget import cache_nbytes, process_footprint

        family, tokenizer = load(entrypoint, drafter="", vision=False, vision_urls=False)
        tokenizer._chat_template = render
        plan = _prefill_plan(tokenizer, self.prefill_step)
        engine = LaneEngine(
            family,
            max_rows=1,
            max_draft=0,
            retain_finished_caches=False,
            prefill_plan=plan,
        )
        cache_types = {ArraysCache, KVCache, AlternatingKVCache}

        def copies(cache: list[Any]) -> tuple[int, int]:
            # Reserve a full qualified working-cache capacity even for a small
            # prefix/view, covering its backing arrays and materialization.
            if any(type(layer) not in cache_types for layer in cache):
                raise ValueError("cache implementation is not admitted")
            return self.bounds.working_bytes, self.bounds.working_bytes

        def copy_settlement(_engine: Any, cache: list[Any]) -> bool:
            arrays = []
            for layer in cache:
                for value in vars(layer).values():
                    values = value if isinstance(value, list) else [value]
                    arrays.extend(v for v in values if isinstance(v, mx.array))
            if arrays:
                mx.eval(*arrays)
            mx.synchronize()
            return True

        def request_settlement(_engine: Any) -> bool:
            mx.synchronize()
            return True

        eos = tuple(tokenizer.eos_token_ids)
        driver = TensorFoldDriver.from_tensorfold(
            engine,
            bounds=self.bounds,
            copy_bounds=copies,
            copy_settlement=copy_settlement,
            request_settlement=request_settlement,
            on_quarantine=quarantine,
            eos_ids=frozenset(eos),
            memory_observer=MemoryObserver(
                active=mx.get_active_memory,
                cache=mx.get_cache_memory,
                peak=mx.get_peak_memory,
                reset_peak=mx.reset_peak_memory,
                footprint=process_footprint,
                estimate=cache_nbytes,
            ),
        )
        session = SimpleNamespace(
            model=family,
            tokenizer=tokenizer,
            eos_token_ids=eos,
            decode_cancel_stride=1,
            prefill_step_size=self.prefill_step,
            prefix_cache=None,
            tool_calling=_tool_calling_metadata(tokenizer),
        )

        def make_sampling(prompt: tuple[int, ...], temperature: float, top_p: float) -> Any:
            if temperature == 0:
                return None
            # Use admitted Orchard options, without provider top-k/min-p
            # defaults or ambient seed salt becoming an unbound control.
            return Sampling(
                seed=seed_for(prompt, salt=0),
                temperature=temperature,
                top_p=top_p,
                top_k=0,
                min_p=0,
            )

        return RuntimeAssets(
            session,
            driver,
            render,
            lambda text: tokenizer.encode(text, add_special_tokens=False),
            make_sampling,
        )
