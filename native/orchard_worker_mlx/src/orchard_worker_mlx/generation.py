"""Real MLX token generation via mlx_lm.stream_generate().

This module owns request-time generation only: prompt decode/encode, sampler
construction, stream_generate invocation, prefill progress bridging, stop-
sequence buffering, Orchard-level EOS detection, delta normalization, terminal
event emission, usage accounting, and strided decode-phase cancel checks.

It does NOT own model lifecycle, gRPC/proto conversion, or accepted events.

Request-local KV prefix-cache lookup/store (Task 6):
    When ``session.prefix_cache`` is a live ``KVPrefixCache`` and the
    generation deps include prompt-cache helpers, this module performs
    cache lookup before ``stream_generate()`` and stores the mutated
    cache on successful completion only.  All cache operations are
    fail-open: errors fall through to uncached generation.

Key invariant — add_special_tokens=False:
    ``request.rendered_prompt_utf8`` arrives fully rendered by the controller
    (chat template, system prompt scaffolding, BOS tokens already applied).
    This module tokenizes the rendered prompt **without** adding tokenizer-
    level special tokens.  Violating this would duplicate BOS/chat-template
    tokens, alter prompt semantics, and skew usage counts.

Stop-sequence buffering (Task 4):
    Deltas emitted to downstream consumers are irreversible (gRPC stream).
    ``StopSequenceBuffer`` withholds a trailing suffix that could still match
    a configured stop sequence, emitting only the safe prefix.  When a stop
    is found the marker is suppressed and ``finish_reason = STOP`` is set.
    On non-stop terminals (EOS, length, cancel) the buffer is flushed.

Orchard-level EOS detection (Task 4):
    ``mlx_lm.stream_generate()`` only honors ``tokenizer.eos_token_id``
    (singular).  Models with config-only EOS IDs are not covered.  This
    module checks each ``response.token`` against ``session.eos_token_ids``
    (computed at load time by ``_normalize_eos_token_ids()``) for
    comprehensive stop handling.

Prefill progress bridging (Task 5):
    ``mlx_lm.stream_generate()`` accepts ``prompt_progress_callback`` and
    ``prefill_step_size`` kwargs.  The callback is invoked synchronously
    during prefill with ``(processed_tokens, total_tokens)``.  This module
    bridges the synchronous callback into yielded ``progress`` events by
    queuing updates in a request-local deque and draining them before each
    token delta.  Prefill cancel is NOT cleanly interruptible — upstream
    ``generate_step()`` has no cancel hook; cancellation applies only after
    control returns from prefill (i.e., during decode).
"""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass, field, is_dataclass, replace
from types import SimpleNamespace
from typing import Any, cast

from orchard_worker_mlx.backends import BackendError, cancelled_event
from orchard_worker_mlx.prefix_cache import PrefixCacheStats
from orchard_worker_mlx.tool_calling import (
    build_context as build_tool_calling_context,
)
from orchard_worker_mlx.tool_calling import (
    consume_response as consume_tool_response,
)
from orchard_worker_mlx.tool_calling import (
    finalize as finalize_tool_calling,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Cache telemetry types (internal)
# ---------------------------------------------------------------------------

# Lookup status constants
_LOOKUP_DISABLED = "disabled"
_LOOKUP_HELPERS_UNAVAILABLE = "helpers_unavailable"
_LOOKUP_MISS = "miss"
_LOOKUP_PARTIAL_HIT = "partial_hit"
_LOOKUP_FULL_HIT = "full_hit"
_LOOKUP_FAILED = "lookup_failed"

# Store status constants
_STORE_NOT_ATTEMPTED = "not_attempted"
_STORE_SKIPPED_UNAVAILABLE = "skipped_unavailable"
_STORE_SKIPPED_MISSING_TOKEN_ID = "skipped_missing_token_id"
_STORE_SKIPPED_UNFINALIZED_BATCH = "skipped_unfinalized_batch"
_STORE_SKIPPED_OVERSIZE = "skipped_oversize"
_STORE_STORED = "stored"
_STORE_FAILED = "store_failed"


@dataclass(slots=True)
class _CacheLookupResult:
    """Structured outcome of prefix-cache lookup."""

    status: str = _LOOKUP_DISABLED
    prompt_cache: Any = None
    stream_prompt_ids: list[int] = field(default_factory=list)
    matched_tokens: int = 0
    remaining_tokens: int = 0
    lookup_ms: float = 0.0
    stats: PrefixCacheStats | None = None


@dataclass(slots=True)
class _CacheStoreResult:
    """Structured outcome of prefix-cache store."""

    status: str = _STORE_NOT_ATTEMPTED
    store_ms: float = 0.0
    stats: PrefixCacheStats | None = None


# ---------------------------------------------------------------------------
# Dependency injection seam (mirrors MLXDeps in model_loader.py)
# ---------------------------------------------------------------------------


@dataclass(slots=True, frozen=True, kw_only=True)
class GenerationDeps:
    """Narrow test seam for mocked MLX generation.

    NOTE: ``stream_generate`` is also injected in ``model_loader.MLXDeps``
    for warmup inference during load.  The two injection points are
    intentionally separate (different lifecycle: load-time warmup vs
    request-time generation), but both import from
    ``mlx_lm.generate.stream_generate`` in production.  Keep them in sync
    if the upstream API changes.
    """

    stream_generate: Callable[..., Iterator[Any]]
    make_sampler: Callable[..., Any]
    make_prompt_cache: Callable[[Any], Any] | None = None
    trim_prompt_cache: Callable[[Any, int], Any] | None = None
    wired_limit: Callable[[int], Any] | None = None
    current_memory_bytes: Callable[[], int | None] | None = None
    supports_orchard_stop_sequences: bool = True
    uses_shared_batch_runtime: bool = False


def _build_wired_limit_context(mx_module: Any) -> Callable[[int], Any]:
    # Keep this direct mlx.core helper so Orchard can apply its own byte target
    # while preserving the GenerationDeps fail-open/testing seam.
    @contextmanager
    def _wired_limit(target_working_set_bytes: int) -> Iterator[None]:
        old_limit = mx_module.set_wired_limit(target_working_set_bytes)
        try:
            yield
        finally:
            try:
                mx_module.synchronize()
            except Exception:
                logger.debug("wired_limit synchronize failed; continuing", exc_info=True)
            try:
                mx_module.set_wired_limit(old_limit)
            except Exception:
                logger.debug("wired_limit restore failed; continuing", exc_info=True)

    return _wired_limit


def _default_generation_deps() -> GenerationDeps:
    """Import real MLX generation dependencies lazily."""
    try:
        from mlx_lm.generate import stream_generate
        from mlx_lm.sample_utils import make_sampler
    except ImportError as exc:
        raise BackendError(
            "mlx_backend_unavailable",
            f"MLX generation dependencies not available: {exc}",
        ) from exc

    # Optional prompt-cache helpers — fail-open if unavailable.
    _make_prompt_cache: Callable[[Any], Any] | None = None
    _trim_prompt_cache: Callable[[Any, int], Any] | None = None
    _wired_limit: Callable[[int], Any] | None = None
    _current_memory_bytes: Callable[[], int | None] | None = None
    try:
        from mlx_lm.models.cache import (
            make_prompt_cache as _make,
        )
        from mlx_lm.models.cache import (
            trim_prompt_cache as _trim,
        )

        _make_prompt_cache = _make
        _trim_prompt_cache = _trim
    except (ImportError, AttributeError):
        pass

    try:
        import mlx.core as mx

        _wired_limit = _build_wired_limit_context(mx)
        maybe_memory_probe = getattr(mx, "get_active_memory", None)
        if callable(maybe_memory_probe):
            _current_memory_bytes = cast(Callable[[], int | None], maybe_memory_probe)
    except (ImportError, AttributeError):
        pass

    return GenerationDeps(
        stream_generate=stream_generate,
        make_sampler=make_sampler,
        make_prompt_cache=_make_prompt_cache,
        trim_prompt_cache=_trim_prompt_cache,
        wired_limit=_wired_limit,
        current_memory_bytes=_current_memory_bytes,
        supports_orchard_stop_sequences=True,
        uses_shared_batch_runtime=False,
    )


@dataclass(slots=True, frozen=True)
class BatchGenerationDeps:
    """Dependency seam for request-time batching with mlx_lm.BatchGenerator."""

    batch_generator_cls: Any


def _default_batch_generation_deps() -> BatchGenerationDeps:
    try:
        from mlx_lm.generate import BatchGenerator
    except ImportError as exc:
        raise BackendError(
            "mlx_backend_unavailable",
            f"MLX BatchGenerator not available: {exc}",
        ) from exc

    return BatchGenerationDeps(batch_generator_cls=BatchGenerator)


def batch_generation_supported() -> bool:
    """True when mlx_lm.BatchGenerator can be imported in this environment."""
    try:
        _default_batch_generation_deps()
        return True
    except BackendError:
        return False


@dataclass(slots=True)
class _BatchRequestState:
    request_id: int
    prompt_ids: list[int]
    max_tokens: int
    sampler: Any
    prompt_cache: Any | None
    logits_processors: list[Any]
    progress_callback: Callable[[int, int], None] | None
    events: deque[tuple[int, str | None]] = field(default_factory=deque)
    progress_events: deque[tuple[int, int]] = field(default_factory=deque)
    uid: int | None = None
    closed: bool = False
    done: bool = False
    error: Exception | None = None
    cancel_deadline_monotonic: float | None = None
    local_close_deadline_monotonic: float | None = None


_WAIT_NEXT_TIMEOUT = object()


class _BatchRequestStream:
    """Per-request stream view over a shared BatchGenerator runtime."""

    def __init__(
        self,
        runtime: BatchGeneratorRuntime,
        request_id: int,
        *,
        cancel_event: threading.Event | None = None,
    ) -> None:
        self._runtime = runtime
        self._request_id = request_id
        self._cancel_event = cancel_event

        detokenizer = runtime.acquire_detokenizer()
        try:
            detokenizer.reset()
        except Exception:
            runtime.release_detokenizer(detokenizer)
            raise

        self._detokenizer = detokenizer
        self._stop_token_ids: frozenset[int] = runtime.stop_token_ids
        self._closed = False
        self._terminal_returned = False
        self._released_detokenizer = False

    def __iter__(self) -> _BatchRequestStream:
        return self

    def __next__(self) -> Any:
        if self._terminal_returned:
            self._release_detokenizer()
            raise StopIteration

        try:
            while True:
                state, payload = self._runtime.wait_next(
                    self._request_id,
                    timeout_s=0.05 if self._cancel_event is not None else None,
                )

                if payload is _WAIT_NEXT_TIMEOUT:
                    if self._cancel_event is not None and self._cancel_event.is_set():
                        self.close(cancelled=True)
                        raise StopIteration
                    continue

                if payload is None:
                    self._runtime.finalize_request(self._request_id)
                    self._release_detokenizer()
                    raise StopIteration

                payload_tuple = cast(tuple[Any, ...], payload)
                kind = payload_tuple[0]
                if kind == "progress":
                    _, processed, total = payload_tuple
                    cb = state.progress_callback
                    if cb is not None:
                        cb(processed, total)
                    continue

                _, token, finish_reason = payload_tuple

                suppress_terminal_stop_token = (
                    finish_reason == "stop" and token in self._stop_token_ids
                )
                if suppress_terminal_stop_token:
                    text = ""
                else:
                    self._detokenizer.add_token(token)
                    text = self._detokenizer.last_segment

                if finish_reason is not None:
                    if not suppress_terminal_stop_token:
                        self._detokenizer.finalize()
                        tail = self._detokenizer.last_segment
                        if tail:
                            text += tail
                    self._terminal_returned = True
                    self._runtime.finalize_request(self._request_id)
                    self._release_detokenizer()
                return SimpleNamespace(text=text, token=token, finish_reason=finish_reason)
        except Exception:
            self._runtime.finalize_request(self._request_id)
            self._release_detokenizer()
            raise

    def close(self, *, cancelled: bool = True) -> None:
        if self._closed:
            return
        self._closed = True

        if cancelled:
            self._runtime.cancel(self._request_id)
            self._runtime.finalize_request(self._request_id, keep_active=True)
        elif self._terminal_returned:
            self._runtime.finalize_request(self._request_id)
        else:
            self._runtime.finalize_request(
                self._request_id,
                keep_active=True,
                local_close=True,
            )

        self._release_detokenizer()

    def _release_detokenizer(self) -> None:
        if self._released_detokenizer:
            return
        self._released_detokenizer = True
        self._runtime.release_detokenizer(self._detokenizer)


_BATCH_CANCEL_DRAIN_TIMEOUT_S = 0.5
_BATCH_LOCAL_CLOSE_DRAIN_TIMEOUT_S = 0.5
_BATCH_RUNTIME_CLOSE_TIMEOUT_S = 1.0


class BatchGeneratorRuntime:
    """Shared request-time BatchGenerator runtime for one loaded model session."""

    def __init__(
        self,
        session: Any,
        *,
        generation_deps: GenerationDeps | None = None,
        batch_deps: BatchGenerationDeps | None = None,
    ) -> None:
        self._session = session
        self._generation_deps = generation_deps or _default_generation_deps()
        self._batch_deps = batch_deps or _default_batch_generation_deps()

        self._lock = threading.Lock()
        self._cv = threading.Condition(self._lock)
        self._closed = False
        self._next_request_id = 0
        self._pending_request_ids: deque[int] = deque()
        self._pending_by_id: dict[int, _BatchRequestState] = {}
        self._active_by_uid: dict[int, _BatchRequestState] = {}
        self._requests_by_id: dict[int, _BatchRequestState] = {}
        self._detokenizer_lock = threading.Lock()
        self._active_detokenizer_ids: set[int] = set()
        self._detokenizer_factory = self._build_detokenizer_factory(session.tokenizer)
        self._batch_generator_closed = False
        self._wired_limit_stack = ExitStack()
        self._wired_limit_closed = False
        self.stop_token_ids: frozenset[int] = frozenset(getattr(session, "eos_token_ids", ()))

        self._reset_requested: str | None = None
        try:
            _enter_wired_limit_fail_open(
                self._wired_limit_stack,
                session,
                self._generation_deps,
                allow_shared_batch_runtime=True,
            )
            self._batch_generator = self._build_batch_generator(session)
            self._pump = threading.Thread(
                target=self._run_loop, name="mlx-batch-generator", daemon=True
            )
            self._watchdog = threading.Thread(
                target=self._deadline_watchdog_loop,
                name="mlx-batch-generator-watchdog",
                daemon=True,
            )
            self._pump.start()
            self._watchdog.start()
        except Exception:
            self._cleanup_partial_startup()
            raise

    @property
    def tokenizer(self) -> Any:
        return self._session.tokenizer

    def generation_deps(self) -> GenerationDeps:
        return GenerationDeps(
            stream_generate=self.stream_generate,
            make_sampler=self._generation_deps.make_sampler,
            make_prompt_cache=self._generation_deps.make_prompt_cache,
            trim_prompt_cache=self._generation_deps.trim_prompt_cache,
            wired_limit=self._generation_deps.wired_limit,
            current_memory_bytes=self._generation_deps.current_memory_bytes,
            supports_orchard_stop_sequences=False,
            uses_shared_batch_runtime=True,
        )

    def acquire_detokenizer(self) -> Any:
        detokenizer = self._detokenizer_factory()
        self._validate_detokenizer(detokenizer)

        detokenizer_id = id(detokenizer)
        with self._detokenizer_lock:
            if detokenizer_id in self._active_detokenizer_ids:
                raise BackendError(
                    "generation_failed",
                    "batch detokenizer instance is shared across requests",
                    False,
                )
            self._active_detokenizer_ids.add(detokenizer_id)

        return detokenizer

    def release_detokenizer(self, detokenizer: Any) -> None:
        with self._detokenizer_lock:
            self._active_detokenizer_ids.discard(id(detokenizer))

    def stream_generate(
        self,
        model: Any,
        tokenizer: Any,
        prompt_ids: list[int],
        **kwargs: Any,
    ) -> Iterator[Any]:
        del model, tokenizer
        stream = self._submit(prompt_ids, kwargs)
        return stream

    def close(self) -> None:
        with self._cv:
            if self._closed and self._batch_generator_closed:
                self._close_wired_limit()
                return

            self._closed = True
            self._mark_all_closed_locked(
                BackendError("generation_failed", "batch runtime closed", False)
            )
            batch_generator = self._batch_generator
            self._cv.notify_all()

        self._close_batch_generator_best_effort(batch_generator)

        if self._pump.is_alive() and threading.current_thread() is not self._pump:
            self._pump.join(timeout=_BATCH_RUNTIME_CLOSE_TIMEOUT_S)

        if self._watchdog.is_alive() and threading.current_thread() is not self._watchdog:
            self._watchdog.join(timeout=_BATCH_RUNTIME_CLOSE_TIMEOUT_S)

        if self._pump.is_alive():
            raise BackendError(
                "batch_runtime_close_timeout",
                "batch runtime did not stop after closing BatchGenerator",
                True,
            )

        with self._cv:
            self._batch_generator_closed = True

        self._close_wired_limit()

    def wait_next(
        self,
        request_id: int,
        *,
        timeout_s: float | None = None,
    ) -> tuple[_BatchRequestState, tuple[Any, ...] | None | object]:
        with self._cv:
            state = self._requests_by_id[request_id]

            while True:
                if state.progress_events:
                    processed, total = state.progress_events.popleft()
                    return state, ("progress", processed, total)

                if state.events:
                    token, finish_reason = state.events.popleft()
                    return state, ("token", token, finish_reason)

                if state.error is not None:
                    raise state.error

                if state.done:
                    return state, None

                if timeout_s is None:
                    self._cv.wait()
                elif not self._cv.wait(timeout=timeout_s):
                    return state, _WAIT_NEXT_TIMEOUT

    def cancel(self, request_id: int) -> None:
        with self._cv:
            state = self._requests_by_id.get(request_id)
            if state is None:
                return

            state.closed = True
            state.done = True
            if state.uid is not None:
                state.cancel_deadline_monotonic = time.monotonic() + _BATCH_CANCEL_DRAIN_TIMEOUT_S
                state.local_close_deadline_monotonic = None
            else:
                self._finalize_request_locked(state)

            self._pending_by_id.pop(request_id, None)
            self._pending_request_ids = deque(
                rid for rid in self._pending_request_ids if rid != request_id
            )
            self._cv.notify_all()

    def finalize_request(
        self,
        request_id: int,
        *,
        keep_active: bool = False,
        local_close: bool = False,
    ) -> None:
        with self._cv:
            state = self._requests_by_id.get(request_id)
            if state is None:
                return
            self._finalize_request_locked(
                state,
                keep_active=keep_active,
                local_close=local_close,
            )
            self._cv.notify_all()

    def _submit(self, prompt_ids: list[int], kwargs: dict[str, Any]) -> _BatchRequestStream:
        max_tokens = _safe_int(kwargs.get("max_tokens", 0), default=0)
        cancel_event = kwargs.get("cancel_event")
        if max_tokens <= 0:
            max_tokens = 1

        with self._cv:
            if self._closed:
                raise BackendError("generation_failed", "batch runtime is closed", False)

            request_id = self._next_request_id
            self._next_request_id += 1
            request_state = _BatchRequestState(
                request_id=request_id,
                prompt_ids=list(prompt_ids),
                max_tokens=max_tokens,
                sampler=kwargs.get("sampler"),
                prompt_cache=kwargs.get("prompt_cache"),
                logits_processors=[],
                progress_callback=kwargs.get("prompt_progress_callback"),
            )
            self._requests_by_id[request_id] = request_state
            self._pending_by_id[request_id] = request_state
            self._pending_request_ids.append(request_id)
            self._cv.notify_all()

        try:
            return _BatchRequestStream(self, request_id, cancel_event=cancel_event)
        except Exception:
            self.finalize_request(request_id)
            raise

    def _build_detokenizer_factory(self, tokenizer: Any) -> Callable[[], Any]:
        maker = getattr(tokenizer, "make_detokenizer", None)
        if callable(maker):
            factory: Callable[[], Any] = maker
        else:
            try:
                _ = tokenizer.detokenizer
            except Exception as exc:
                raise BackendError(
                    "batch_runtime_unavailable",
                    f"batch tokenizer detokenizer unavailable: {exc}",
                    False,
                ) from exc

            def factory() -> Any:
                return tokenizer.detokenizer

        first = factory()
        second = factory()
        self._validate_detokenizer(first)
        self._validate_detokenizer(second)
        if first is second:
            raise BackendError(
                "batch_runtime_unavailable",
                "batch tokenizer returned a shared detokenizer instance",
                False,
            )

        return factory

    def _validate_detokenizer(self, detokenizer: Any) -> None:
        if detokenizer is None:
            raise BackendError(
                "batch_runtime_unavailable",
                "batch tokenizer detokenizer is missing",
                False,
            )

        for method_name in ("reset", "add_token", "finalize"):
            method = getattr(detokenizer, method_name, None)
            if not callable(method):
                raise BackendError(
                    "batch_runtime_unavailable",
                    f"batch tokenizer detokenizer missing {method_name}()",
                    False,
                )

        if not hasattr(detokenizer, "last_segment"):
            raise BackendError(
                "batch_runtime_unavailable",
                "batch tokenizer detokenizer missing last_segment",
                False,
            )

    def _build_batch_generator(self, session: Any) -> Any:
        return self._batch_deps.batch_generator_cls(
            session.model,
            stop_tokens=set(getattr(session, "eos_token_ids", ())),
            prefill_step_size=_prefill_step_size(session),
            prompt_progress_callback=self._on_prompt_progress,
        )

    def _on_prompt_progress(self, updates: list[tuple[int, int, int]]) -> None:
        with self._cv:
            for uid, processed, total in updates:
                state = self._active_by_uid.get(uid)
                if state is None or state.closed:
                    continue
                state.progress_events.append((processed, total))
            self._cv.notify_all()

    def _run_loop(self) -> None:
        while True:
            pending_states: list[_BatchRequestState] = []
            perform_reset = False

            with self._cv:
                while (
                    not self._closed
                    and self._reset_requested is None
                    and not self._pending_request_ids
                    and not self._active_by_uid
                ):
                    self._cv.wait()

                if self._closed:
                    self._mark_all_closed_locked(
                        BackendError("generation_failed", "batch runtime closed", False)
                    )
                    return

                if self._reset_requested is not None:
                    perform_reset = True
                else:
                    pending_ids = list(self._pending_request_ids)
                    self._pending_request_ids.clear()
                    for request_id in pending_ids:
                        state = self._pending_by_id.pop(request_id, None)
                        if state is None or state.closed:
                            continue
                        pending_states.append(state)

            if perform_reset:
                self._perform_requested_reset()
                continue

            if pending_states:
                try:
                    raw_uids = self._batch_generator.insert(
                        [state.prompt_ids for state in pending_states],
                        max_tokens=[state.max_tokens for state in pending_states],
                        caches=[state.prompt_cache for state in pending_states],
                        samplers=[state.sampler for state in pending_states],
                        logits_processors=[state.logits_processors for state in pending_states],
                    )
                    uids = self._validate_insert_uids(raw_uids, expected_count=len(pending_states))
                except BackendError as exc:
                    self._mark_states_failed(pending_states, exc)
                    continue
                except Exception as exc:
                    self._mark_states_failed(
                        pending_states,
                        BackendError("generation_failed", f"batch insert failed: {exc}", False),
                    )
                    continue

                with self._cv:
                    for index, state in enumerate(pending_states):
                        uid = uids[index]
                        state.uid = uid
                        self._active_by_uid[uid] = state

            with self._cv:
                if self._closed:
                    self._mark_all_closed_locked(
                        BackendError("generation_failed", "batch runtime closed", False)
                    )
                    return

                if self._reset_requested is not None:
                    perform_reset = True
                    has_active = False
                else:
                    has_active = bool(self._active_by_uid)

            if perform_reset:
                self._perform_requested_reset()
                continue

            if not has_active:
                continue

            try:
                responses = self._batch_generator.next()
            except Exception as exc:
                with self._cv:
                    if self._closed or self._reset_requested is not None:
                        self._cv.notify_all()
                        continue
                self._mark_all_failed(
                    BackendError("generation_failed", f"batch generation failed: {exc}", False)
                )
                continue

            try:
                response_iter = iter(responses)
            except TypeError:
                self._mark_all_failed(
                    BackendError(
                        "generation_failed",
                        "batch generation failed: invalid response container",
                        False,
                    )
                )
                continue

            for response in response_iter:
                if not self._apply_batch_response(response):
                    self._mark_all_failed(
                        BackendError(
                            "generation_failed",
                            "batch generation failed: malformed response payload",
                            False,
                        )
                    )
                    break

    def _finalize_request_locked(
        self,
        state: _BatchRequestState,
        *,
        keep_active: bool = False,
        keep_request: bool = False,
        local_close: bool = False,
    ) -> None:
        request_id = state.request_id
        if not keep_request:
            self._requests_by_id.pop(request_id, None)
        self._pending_by_id.pop(request_id, None)
        self._pending_request_ids = deque(
            rid for rid in self._pending_request_ids if rid != request_id
        )

        if state.uid is not None and not keep_active:
            self._active_by_uid.pop(state.uid, None)

        state.done = True
        state.closed = True
        if keep_active:
            state.local_close_deadline_monotonic = (
                time.monotonic() + _BATCH_LOCAL_CLOSE_DRAIN_TIMEOUT_S if local_close else None
            )
        else:
            state.cancel_deadline_monotonic = None
            state.local_close_deadline_monotonic = None

    def _validate_insert_uids(self, raw_uids: Any, *, expected_count: int) -> list[int]:
        try:
            uids = list(raw_uids)
        except TypeError as exc:
            raise BackendError(
                "generation_failed",
                "batch insert returned a non-iterable uid container",
                False,
            ) from exc

        if len(uids) != expected_count:
            raise BackendError(
                "generation_failed",
                "batch insert returned an unexpected uid count",
                False,
            )

        seen: set[int] = set()
        for uid in uids:
            if isinstance(uid, bool) or not isinstance(uid, int):
                raise BackendError(
                    "generation_failed",
                    "batch insert returned an invalid uid",
                    False,
                )
            if uid in seen:
                raise BackendError(
                    "generation_failed",
                    "batch insert returned duplicate uids",
                    False,
                )
            seen.add(uid)

        return uids

    def _apply_batch_response(self, response: Any) -> bool:
        uid = getattr(response, "uid", None)
        token = getattr(response, "token", None)
        finish_reason = getattr(response, "finish_reason", None)

        if isinstance(uid, bool) or not isinstance(uid, int):
            return False

        if isinstance(token, bool) or not isinstance(token, int):
            self._fail_active_request(
                uid,
                BackendError(
                    "generation_failed",
                    "batch response token is invalid",
                    False,
                ),
            )
            return True

        if finish_reason is not None and not isinstance(finish_reason, str):
            self._fail_active_request(
                uid,
                BackendError(
                    "generation_failed",
                    "batch response finish_reason is invalid",
                    False,
                ),
            )
            return True

        with self._cv:
            state = self._active_by_uid.get(uid)
            if state is None:
                return True

            if not state.closed:
                state.events.append((token, finish_reason))

            if finish_reason is not None:
                self._finalize_request_cache(state, response)
                self._finalize_request_locked(state, keep_request=True)

            self._cv.notify_all()

        return True

    def _fail_active_request(self, uid: int, error: Exception) -> None:
        with self._cv:
            state = self._active_by_uid.get(uid)
            if state is None:
                return
            state.error = error
            self._finalize_request_locked(state, keep_request=True)
            self._cv.notify_all()

    def _deadline_watchdog_loop(self) -> None:
        while True:
            batch_generator = None
            with self._cv:
                if self._closed:
                    return

                now = time.monotonic()
                has_cancel_timeout = any(
                    state.cancel_deadline_monotonic is not None
                    and state.cancel_deadline_monotonic <= now
                    for state in self._active_by_uid.values()
                )
                has_local_close_timeout = any(
                    state.local_close_deadline_monotonic is not None
                    and state.local_close_deadline_monotonic <= now
                    for state in self._active_by_uid.values()
                )

                if self._reset_requested is None and (
                    has_cancel_timeout or has_local_close_timeout
                ):
                    message = (
                        "batch runtime reset after cancellation drain timeout"
                        if has_cancel_timeout
                        else "batch runtime reset after local-close drain timeout"
                    )
                    batch_generator = self._request_reset_locked(message)
                else:
                    timeout = self._seconds_until_next_deadline_locked(now)
                    self._cv.wait(timeout=timeout)
                    continue

            if batch_generator is not None:
                self._close_batch_generator_best_effort(batch_generator)

    def _cleanup_partial_startup(self) -> None:
        batch_generator = getattr(self, "_batch_generator", None)
        pump = getattr(self, "_pump", None)
        watchdog = getattr(self, "_watchdog", None)

        with self._cv:
            self._closed = True
            self._mark_all_closed_locked(
                BackendError("generation_failed", "batch runtime startup failed", False)
            )
            self._cv.notify_all()

        self._close_batch_generator_best_effort(batch_generator)

        if (
            isinstance(pump, threading.Thread)
            and pump.is_alive()
            and threading.current_thread() is not pump
        ):
            pump.join(timeout=_BATCH_RUNTIME_CLOSE_TIMEOUT_S)

        if (
            isinstance(watchdog, threading.Thread)
            and watchdog.is_alive()
            and threading.current_thread() is not watchdog
        ):
            watchdog.join(timeout=_BATCH_RUNTIME_CLOSE_TIMEOUT_S)

        # Only restore wired-limit once the pump is confirmed dead/not started;
        # a live pump may still be unwinding MLX work.
        if not isinstance(pump, threading.Thread) or not pump.is_alive():
            with self._cv:
                self._batch_generator_closed = True
            self._close_wired_limit()

    def _seconds_until_next_deadline_locked(self, now: float) -> float:
        deadlines = [
            deadline
            for state in self._active_by_uid.values()
            for deadline in (state.cancel_deadline_monotonic, state.local_close_deadline_monotonic)
            if deadline is not None
        ]
        if not deadlines:
            return 0.1
        return max(0.0, min(deadlines) - now)

    def _request_reset_locked(self, message: str) -> Any | None:
        if self._closed or self._reset_requested is not None:
            return None

        self._reset_requested = message
        reset_error = BackendError(
            "generation_failed",
            # Intentional policy: true deadline drain timeout is treated as a
            # retryable collateral failure for other active batch requests.
            message,
            True,
        )

        pending = list(self._pending_by_id.values())
        self._pending_by_id.clear()
        self._pending_request_ids.clear()

        active = list(self._active_by_uid.values())
        self._active_by_uid.clear()

        for state in pending:
            state.error = reset_error
            self._finalize_request_locked(state, keep_request=True)

        for state in active:
            if state.closed:
                self._finalize_request_locked(state, keep_request=True)
            else:
                state.error = reset_error
                self._finalize_request_locked(state, keep_request=True)

        self._cv.notify_all()
        return self._batch_generator

    def _perform_requested_reset(self) -> None:
        with self._cv:
            if self._closed or self._reset_requested is None:
                return
            self._reset_requested = None

        try:
            new_batch_generator = self._build_batch_generator(self._session)
        except Exception:
            self._mark_all_failed(
                BackendError(
                    "generation_failed",
                    "batch runtime reset failed",
                    False,
                )
            )
            with self._cv:
                self._closed = True
                self._cv.notify_all()
            return

        with self._cv:
            if self._closed:
                self._cv.notify_all()
                return
            self._batch_generator = new_batch_generator
            self._batch_generator_closed = False
            self._cv.notify_all()

    def _close_batch_generator_best_effort(self, batch_generator: Any | None) -> None:
        close_fn = getattr(batch_generator, "close", None)
        if callable(close_fn):
            try:
                close_fn()
            except Exception:
                pass

    def _close_wired_limit(self) -> None:
        if self._wired_limit_closed:
            return

        self._wired_limit_closed = True
        try:
            self._wired_limit_stack.close()
        except Exception:
            logger.debug("wired_limit close failed; continuing", exc_info=True)

    def _finalize_request_cache(self, state: _BatchRequestState, response: Any) -> None:
        if state.prompt_cache is None:
            return

        cache_fn = getattr(response, "prompt_cache", None)
        if not callable(cache_fn):
            return

        try:
            extracted = list(cache_fn())
        except Exception:
            return

        try:
            state.prompt_cache.clear()
            state.prompt_cache.extend(extracted)
        except Exception:
            pass

    def _mark_states_failed(self, states: list[_BatchRequestState], error: Exception) -> None:
        with self._cv:
            for state in states:
                state.error = error
                self._finalize_request_locked(state, keep_request=True)
            self._cv.notify_all()

    def _mark_all_failed(self, error: Exception) -> None:
        with self._cv:
            targets = list(self._requests_by_id.values())
            self._pending_by_id.clear()
            self._pending_request_ids.clear()
            self._active_by_uid.clear()
            for state in targets:
                state.error = error
                self._finalize_request_locked(state, keep_request=True)
            self._cv.notify_all()

    def _mark_all_closed_locked(self, error: Exception) -> None:
        targets = list(self._requests_by_id.values())
        self._pending_by_id.clear()
        self._pending_request_ids.clear()
        self._active_by_uid.clear()
        for state in targets:
            state.error = error
            self._finalize_request_locked(state, keep_request=True)
        self._cv.notify_all()


# ---------------------------------------------------------------------------
# Stop-sequence buffer
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class StopSequenceBuffer:
    """Buffer that withholds text that could still match a stop sequence.

    Operates on Python ``str`` (already decoded from MLX).  Multi-byte UTF-8
    is safe because Python string indexing operates on Unicode code points.

    When no stop sequences are configured, ``push()`` passes text through
    immediately and ``flush()`` is a no-op.
    """

    stop_sequences: tuple[str, ...]
    max_stop_len: int
    pending: str = ""

    def push(self, delta: str) -> tuple[str, bool]:
        """Append *delta* and return ``(safe_text, matched_stop)``.

        *safe_text* is the prefix that cannot be part of a stop sequence.
        *matched_stop* is ``True`` when a stop sequence was found and
        suppressed.
        """
        if not self.stop_sequences:
            return (delta, False)

        self.pending += delta

        # Search for the earliest (and longest on tie) stop sequence.
        best_pos: int | None = None
        best_len: int = 0
        for seq in self.stop_sequences:
            pos = self.pending.find(seq)
            if pos != -1:
                if best_pos is None or pos < best_pos or (pos == best_pos and len(seq) > best_len):
                    best_pos = pos
                    best_len = len(seq)

        if best_pos is not None:
            emit = self.pending[:best_pos]
            self.pending = ""
            return (emit, True)

        # No match: retain a suffix that could still become a partial match.
        retain = self.max_stop_len - 1
        if retain <= 0:
            emit = self.pending
            self.pending = ""
            return (emit, False)

        if len(self.pending) <= retain:
            return ("", False)

        emit = self.pending[:-retain]
        self.pending = self.pending[-retain:]
        return (emit, False)

    def flush(self) -> str:
        """Return all remaining pending text and clear the buffer."""
        text = self.pending
        self.pending = ""
        return text


# ---------------------------------------------------------------------------
# Stop / cancel / EOS helpers
# ---------------------------------------------------------------------------


def _normalize_stop_sequences(params: Any) -> tuple[str, ...]:
    """Extract and deduplicate stop sequences from request params.

    Returns an empty tuple when no valid stop sequences are present.
    Invalid entries (non-string, empty) are silently dropped.
    """
    raw = getattr(params, "stop_sequences", None) if params else None
    if not raw:
        return ()
    seen: set[str] = set()
    result: list[str] = []
    for item in raw:
        if isinstance(item, str) and item and item not in seen:
            seen.add(item)
            result.append(item)
    return tuple(result)


def _decode_cancel_stride(session: Any) -> int:
    """Read cancel stride from session, clamping invalid values to 1."""
    raw = getattr(session, "decode_cancel_stride", 1)
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return 1
    return raw


def _response_token_id(response: Any) -> int | None:
    """Extract token ID from a generation response, or None."""
    token = getattr(response, "token", None)
    if isinstance(token, bool) or not isinstance(token, int):
        return None
    return token


def _close_stream(stream: Any, *, cancelled: bool = True) -> None:
    """Best-effort close of a stream_generate iterator."""
    close = getattr(stream, "close", None)
    if close is not None:
        try:
            if cancelled:
                close()
            else:
                close(cancelled=False)
        except TypeError:
            close()
        except Exception:
            pass


def _cache_finalized_for_store(stream: Any) -> bool:
    if isinstance(stream, _BatchRequestStream):
        return stream._terminal_returned
    return True


def _prefill_step_size(session: Any) -> int:
    """Read prefill step size from session, defaulting to 2048."""
    raw = getattr(session, "prefill_step_size", 2048)
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 1:
        return 2048
    return raw


def _make_prefill_progress_callback(
    queue: deque[tuple[int, int]],
) -> Callable[[int, int], None]:
    """Build a callback for ``prompt_progress_callback`` that queues updates.

    The callback is invoked synchronously by ``mlx_lm.generate_step()``
    during chunked prefill with ``(processed_tokens, total_tokens)``.

    THREAD-SAFETY: Both ``queue`` (``collections.deque``) and ``last``
    (plain list used as mutable closure cell) are **unsynchronized**.  This
    is correct because upstream ``mlx_lm.stream_generate()`` invokes the
    callback synchronously on the same thread that drives the iterator.
    All callback invocations complete before the first ``yield`` from the
    iterator, so there is no concurrent access between callback writes
    and ``generate_events()``'s drain reads.  If upstream ever changes to
    invoke the callback from a background thread, this bridge must be
    updated to use a ``threading.Lock`` around ``last`` and a thread-safe
    queue.

    Sanitization rules:
    - Reject booleans and non-ints.
    - Reject ``total <= 0``.
    - Clamp ``processed`` to ``[0, total]``.
    - Reject ``processed == 0`` (initial zero-progress call is noise).
    - Drop duplicate or non-monotonic updates.
    """
    last: list[tuple[int, int]] = []  # mutable cell: [(last_processed, last_total)]

    def callback(processed: int, total: int) -> None:
        # Type guards.
        if isinstance(processed, bool) or not isinstance(processed, int):
            return
        if isinstance(total, bool) or not isinstance(total, int):
            return
        if total <= 0:
            return

        # Clamp processed into [0, total].
        processed = max(0, min(processed, total))

        # Skip initial zero-progress call.
        if processed == 0:
            return

        # Monotonicity check.
        if last:
            prev_processed, prev_total = last[0]
            if total < prev_total:
                return  # total decreased — nonsensical
            if processed < prev_processed:
                return  # processed regressed even if total grew
            if total == prev_total and processed <= prev_processed:
                return  # not advancing

        last.clear()
        last.append((processed, total))
        queue.append((processed, total))

    return callback


def _drain_prefill_progress(
    queue: deque[tuple[int, int]],
    *,
    last_processed_tokens_out: list[int] | None = None,
) -> Iterator[dict[str, Any]]:
    """Yield queued prefill progress as ``progress`` event dicts."""
    while queue:
        processed, total = queue.popleft()
        if last_processed_tokens_out is not None:
            last_processed_tokens_out.clear()
            last_processed_tokens_out.append(processed)
        yield {
            "kind": "progress",
            "stage": "prefill",
            "message": f"processed {processed}/{total} prompt tokens",
        }


def _sample_current_memory_bytes_fail_open(deps: GenerationDeps) -> int | None:
    """Best-effort process-memory sample from the optional runtime seam."""
    probe = deps.current_memory_bytes
    if probe is None:
        return None

    try:
        value = probe()
    except Exception:
        return None

    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < 0 or value > 2**64 - 1:
        return None

    return value


def _update_session_prefill_workspace_bytes_per_token_high_water(
    session: Any,
    sampled_bytes_per_token: int,
) -> None:
    """High-water immutable update for ``memory_budget_status`` prefill estimate."""
    if isinstance(sampled_bytes_per_token, bool) or not isinstance(sampled_bytes_per_token, int):
        return
    if sampled_bytes_per_token < 0 or sampled_bytes_per_token > 2**64 - 1:
        return

    budget = getattr(session, "memory_budget_status", None)
    if budget is None or not is_dataclass(budget):
        return

    existing_raw = getattr(budget, "prefill_workspace_bytes_per_token", 0)
    if isinstance(existing_raw, bool) or not isinstance(existing_raw, int) or existing_raw < 0:
        existing = 0
    else:
        existing = existing_raw

    next_value = max(existing, sampled_bytes_per_token)
    if next_value == existing:
        return

    try:
        session.memory_budget_status = replace(
            budget,
            prefill_workspace_bytes_per_token=next_value,
        )
    except Exception:
        return


def _finalize_prefill_workspace_probe_fail_open(
    session: Any,
    deps: GenerationDeps,
    *,
    baseline_memory_bytes: int | None,
    prefill_processed_tokens: int | None,
) -> None:
    """Best-effort stream-prefill estimate update; fails open on all invalid paths."""
    if baseline_memory_bytes is None:
        return
    if (
        prefill_processed_tokens is None
        or isinstance(prefill_processed_tokens, bool)
        or not isinstance(prefill_processed_tokens, int)
        or prefill_processed_tokens <= 0
    ):
        return

    final_memory_bytes = _sample_current_memory_bytes_fail_open(deps)
    if final_memory_bytes is None:
        return

    delta_bytes = final_memory_bytes - baseline_memory_bytes
    if delta_bytes < 0:
        return

    sampled = delta_bytes // prefill_processed_tokens
    if sampled < 0:
        return

    _update_session_prefill_workspace_bytes_per_token_high_water(session, sampled)


def _safe_clear_session_cache(session: Any) -> None:
    """Best-effort post-generation memory cleanup."""
    clear_fn = getattr(session, "clear_cache", None)
    if callable(clear_fn):
        try:
            clear_fn()
        except Exception:
            pass


def _wired_limit_target_working_set_bytes(session: Any) -> int:
    """Return session working-set target bytes when wired_limit should apply."""
    budget = getattr(session, "memory_budget_status", None)
    if budget is None:
        return 0

    if getattr(budget, "budget_available", False) is not True:
        return 0

    target = getattr(budget, "target_working_set_bytes", 0)
    if isinstance(target, bool) or not isinstance(target, int):
        return 0

    return target if target > 0 else 0


def _enter_wired_limit_fail_open(
    stack: ExitStack,
    session: Any,
    deps: GenerationDeps,
    *,
    allow_shared_batch_runtime: bool = False,
) -> None:
    """Best-effort wired-memory limit around request-time generation."""
    if deps.wired_limit is None:
        return
    if deps.uses_shared_batch_runtime and not allow_shared_batch_runtime:
        return

    try:
        target_working_set_bytes = _wired_limit_target_working_set_bytes(session)
        if target_working_set_bytes <= 0:
            return
        stack.enter_context(deps.wired_limit(target_working_set_bytes))
    except Exception:
        logger.debug("wired_limit unavailable at runtime; continuing", exc_info=True)


# ---------------------------------------------------------------------------
# Cache telemetry helpers (internal)
# ---------------------------------------------------------------------------


def _safe_stats(prefix_cache: Any) -> PrefixCacheStats | None:
    """Best-effort stats snapshot.  Returns None on any failure."""
    try:
        stats_fn = getattr(prefix_cache, "stats", None)
        if callable(stats_fn):
            return stats_fn()
    except Exception:
        pass
    return None


def _emit_prefix_cache_log(
    *,
    prompt_tokens: int,
    lookup: _CacheLookupResult,
    store: _CacheStoreResult,
    final_stats: PrefixCacheStats | None,
) -> None:
    """Emit exactly one structured cache log line.  Never raises."""
    try:
        stats = final_stats or store.stats or lookup.stats
        impl = (
            getattr(stats, "implementation", "unknown")
            if stats
            else ("disabled" if lookup.status == _LOOKUP_DISABLED else "unknown")
        )
        entry_count = getattr(stats, "entry_count", 0) if stats else 0
        total_bytes = getattr(stats, "total_bytes", 0) if stats else 0

        logger.info(
            "prefix_cache_request "
            "cache_impl=%s "
            "lookup_status=%s "
            "prompt_tokens=%d "
            "matched_tokens=%d "
            "remaining_tokens=%d "
            "lookup_ms=%.3f "
            "store_status=%s "
            "store_ms=%.3f "
            "entry_count=%d "
            "total_bytes=%d",
            impl,
            lookup.status,
            prompt_tokens,
            lookup.matched_tokens,
            lookup.remaining_tokens,
            lookup.lookup_ms,
            store.status,
            store.store_ms,
            entry_count,
            total_bytes,
        )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# KV prefix-cache helpers (Task 6)
# ---------------------------------------------------------------------------


def _prepare_prompt_cache(
    session: Any,
    prompt_ids: list[int],
    *,
    deps: GenerationDeps,
) -> _CacheLookupResult:
    """Prepare a request-local prompt cache and adjusted prompt IDs.

    Returns a structured ``_CacheLookupResult`` with status, timing, and
    stats.  On any failure or when caching is disabled, ``prompt_cache``
    is ``None`` and ``stream_prompt_ids`` equals the original prompt IDs.
    """
    n = len(prompt_ids)
    prefix_cache = getattr(session, "prefix_cache", None)
    if prefix_cache is None:
        return _CacheLookupResult(
            status=_LOOKUP_DISABLED,
            stream_prompt_ids=prompt_ids,
            remaining_tokens=n,
        )
    if deps.make_prompt_cache is None or deps.trim_prompt_cache is None:
        return _CacheLookupResult(
            status=_LOOKUP_HELPERS_UNAVAILABLE,
            stream_prompt_ids=prompt_ids,
            remaining_tokens=n,
        )

    t0 = time.monotonic()
    pre_stats = _safe_stats(prefix_cache)
    try:
        hit = prefix_cache.lookup(prompt_ids, trim_fn=deps.trim_prompt_cache)
        post_stats = _safe_stats(prefix_cache)
        elapsed = (time.monotonic() - t0) * 1000.0

        if hit is not None:
            is_full = hit.matched_length >= n
            return _CacheLookupResult(
                status=_LOOKUP_FULL_HIT if is_full else _LOOKUP_PARTIAL_HIT,
                prompt_cache=hit.prompt_cache,
                stream_prompt_ids=hit.remaining_ids,
                matched_tokens=hit.matched_length,
                remaining_tokens=len(hit.remaining_ids),
                lookup_ms=elapsed,
                stats=post_stats,
            )

        # Distinguish miss from fail-open failure via stats delta.
        pre_failures = getattr(pre_stats, "failures", 0) if pre_stats else 0
        post_failures = getattr(post_stats, "failures", 0) if post_stats else 0
        if post_failures > pre_failures:
            return _CacheLookupResult(
                status=_LOOKUP_FAILED,
                stream_prompt_ids=prompt_ids,
                remaining_tokens=n,
                lookup_ms=elapsed,
                stats=post_stats,
            )

        # True miss: create a fresh request-local prompt cache.
        fresh = deps.make_prompt_cache(session.model)
        elapsed = (time.monotonic() - t0) * 1000.0
        return _CacheLookupResult(
            status=_LOOKUP_MISS,
            prompt_cache=fresh,
            stream_prompt_ids=prompt_ids,
            remaining_tokens=n,
            lookup_ms=elapsed,
            stats=post_stats,
        )
    except Exception:
        elapsed = (time.monotonic() - t0) * 1000.0
        return _CacheLookupResult(
            status=_LOOKUP_FAILED,
            stream_prompt_ids=prompt_ids,
            remaining_tokens=n,
            lookup_ms=elapsed,
        )


def _maybe_store_prompt_cache(
    session: Any,
    prompt_ids: list[int],
    generated_token_ids: list[int],
    *,
    prompt_cache: Any | None,
    can_store: bool,
    cache_finalized: bool = True,
) -> _CacheStoreResult:
    """Best-effort store of mutated prompt cache after successful generation.

    Returns a structured ``_CacheStoreResult`` with status, timing, and
    stats.  All exceptions are swallowed (fail-open).
    """
    prefix_cache = getattr(session, "prefix_cache", None)
    if prefix_cache is None or prompt_cache is None:
        return _CacheStoreResult(status=_STORE_SKIPPED_UNAVAILABLE)
    if not can_store:
        return _CacheStoreResult(status=_STORE_SKIPPED_MISSING_TOKEN_ID)
    if not cache_finalized:
        return _CacheStoreResult(status=_STORE_SKIPPED_UNFINALIZED_BATCH)
    try:
        t0 = time.monotonic()
        full_key = prompt_ids + generated_token_ids
        accepted = prefix_cache.store(full_key, prompt_cache)
        elapsed = (time.monotonic() - t0) * 1000.0
        status = _STORE_STORED if accepted is not False else _STORE_SKIPPED_OVERSIZE
        return _CacheStoreResult(
            status=status,
            store_ms=elapsed,
            stats=_safe_stats(prefix_cache),
        )
    except Exception:
        elapsed = (time.monotonic() - t0) * 1000.0
        return _CacheStoreResult(
            status=_STORE_FAILED,
            store_ms=elapsed,
            stats=_safe_stats(prefix_cache),
        )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def generate_events(
    session: Any,
    request: Any,
    cancel_event: threading.Event,
    *,
    deps: GenerationDeps | None = None,
) -> Iterator[dict[str, Any]]:
    """Generate inference events from a loaded model session.

    Yields dicts matching ``service.py``'s ``build_inference_event()``
    expectations:

    - ``{"kind": "progress", "stage": "prefill", "message": "..."}``
    - ``{"kind": "output_text_delta", "delta": "..."}``
    - ``{"kind": "tool_call_delta", ...}``
    - ``{"kind": "completed", "finish_reason": "...", "usage": {...}}``
    - ``{"kind": "failed", "code": "...", ...}``  (via ``cancelled_event()``)

    Prefill progress is bridged from ``prompt_progress_callback`` into
    yielded ``progress`` events before token deltas. Stop sequences are
    suppressed via ``StopSequenceBuffer`` for normal text emission only.
    Tool-call mode is mediated through ``tool_calling.py`` and disables stop
    buffering once tool generation starts. Orchard-level EOS detection checks
    ``session.eos_token_ids`` per response. Cancel is checked every
    ``session.decode_cancel_stride`` tokens during decode.

    NOTE(task-5): Prefill cancel is NOT cleanly interruptible. Upstream
    ``generate_step()`` has no cancel hook. Cancellation applies only after
    control returns from prefill (i.e., during decode). This is a known
    limitation documented rather than worked around.

    Raises ``BackendError`` for setup-time failures (invalid prompt, etc.).
    """
    if deps is None:
        deps = _default_generation_deps()

    prompt_text = _decode_prompt(request.rendered_prompt_utf8)

    params = getattr(request, "params", None)
    max_output_tokens = _safe_int(getattr(params, "max_output_tokens", 0) if params else 0)
    temperature = _safe_float(getattr(params, "temperature", 0.0) if params else 0.0)
    top_p = _safe_float(getattr(params, "top_p", 0.0) if params else 0.0)
    input_tokens = _safe_int(getattr(request, "input_tokens", 0))
    stop_sequences = _normalize_stop_sequences(params)

    prompt_tokens = 0
    lookup_result = _CacheLookupResult(status=_LOOKUP_DISABLED)
    store_result = _CacheStoreResult()
    stream: Any | None = None

    try:
        if max_output_tokens <= 0:
            yield _completed_event("FINISH_REASON_LENGTH", input_tokens, 0)
            return

        if stop_sequences and not deps.supports_orchard_stop_sequences:
            yield {
                "kind": "failed",
                "code": "unsupported_generation_params",
                "message": "stop_sequences are not supported with generation_mode=batch",
                "retryable": False,
            }
            return

        prompt_ids = _encode_prompt(session.tokenizer, prompt_text)
        prompt_tokens = len(prompt_ids)
        sampler = _build_sampler(temperature, top_p, deps)

        stride = _decode_cancel_stride(session)
        eos_ids: frozenset[int] = frozenset(getattr(session, "eos_token_ids", ()))
        max_stop_len = max((len(s) for s in stop_sequences), default=0)
        buf = StopSequenceBuffer(stop_sequences=stop_sequences, max_stop_len=max_stop_len)
        tool_context = build_tool_calling_context(session, params)
        tool_calls_emitted = False

        progress_queue: deque[tuple[int, int]] = deque()
        progress_callback = _make_prefill_progress_callback(progress_queue)
        last_prefill_processed_tokens: list[int] = []

        if cancel_event.is_set():
            yield cancelled_event()
            return

        request_prompt_cache = None
        stream_prompt_ids = prompt_ids
        if not deps.uses_shared_batch_runtime:
            lookup_result = _prepare_prompt_cache(session, prompt_ids, deps=deps)
            request_prompt_cache = lookup_result.prompt_cache
            stream_prompt_ids = lookup_result.stream_prompt_ids

        stream_kwargs: dict[str, Any] = {
            "max_tokens": max_output_tokens,
            "sampler": sampler,
            "prefill_step_size": _prefill_step_size(session),
            "prompt_progress_callback": progress_callback,
        }
        if request_prompt_cache is not None:
            stream_kwargs["prompt_cache"] = request_prompt_cache
        if deps.uses_shared_batch_runtime:
            stream_kwargs["cancel_event"] = cancel_event

        with ExitStack() as stack:
            _enter_wired_limit_fail_open(stack, session, deps)

            stream = deps.stream_generate(
                session.model,
                session.tokenizer,
                stream_prompt_ids,
                **stream_kwargs,
            )

            prefill_probe_baseline: int | None = None
            prefill_probe_finalized = False
            if not deps.uses_shared_batch_runtime:
                prefill_probe_baseline = _sample_current_memory_bytes_fail_open(deps)

            def finalize_prefill_probe_if_needed(drained_prefill: bool) -> None:
                nonlocal prefill_probe_finalized

                if not drained_prefill or prefill_probe_finalized or deps.uses_shared_batch_runtime:
                    return

                processed_tokens = (
                    last_prefill_processed_tokens[-1] if last_prefill_processed_tokens else None
                )
                _finalize_prefill_workspace_probe_fail_open(
                    session,
                    deps,
                    baseline_memory_bytes=prefill_probe_baseline,
                    prefill_processed_tokens=processed_tokens,
                )
                prefill_probe_finalized = True

            output_tokens = 0
            generated_token_ids: list[int] = []
            can_store = True

            for response in stream:
                drained_prefill = bool(progress_queue)
                yield from _drain_prefill_progress(
                    progress_queue,
                    last_processed_tokens_out=last_prefill_processed_tokens,
                )
                finalize_prefill_probe_if_needed(drained_prefill)
                output_tokens += 1

                if output_tokens % stride == 0 and cancel_event.is_set():
                    if tool_context is None or not tool_context.stop_buffer_disabled:
                        flush_text = buf.flush()
                        if flush_text:
                            yield {"kind": "output_text_delta", "delta": flush_text}
                    _close_stream(stream, cancelled=True)
                    if tool_context is not None:
                        finalize_tool_calling(tool_context, terminal_kind="cancelled")
                        for event in tool_context.take_pending_events():
                            if event["kind"] == "tool_call_delta":
                                tool_calls_emitted = True
                            yield event
                    yield cancelled_event()
                    return

                finish_reason = response.finish_reason
                token_id = _response_token_id(response)
                orchard_eos = (
                    token_id is not None
                    and bool(eos_ids)
                    and token_id in eos_ids
                    and finish_reason is None
                )

                if token_id is None:
                    can_store = False
                elif can_store:
                    generated_token_ids.append(token_id)

                tool_mode_before = bool(tool_context and tool_context.stop_buffer_disabled)
                emitted_events = (
                    consume_tool_response(tool_context, response)
                    if tool_context is not None
                    else (
                        [{"kind": "output_text_delta", "delta": response.text}]
                        if response.text
                        else []
                    )
                )

                if tool_context is not None and not tool_mode_before and tool_context.in_tool_call:
                    flush_text = buf.flush()
                    if flush_text:
                        yield {"kind": "output_text_delta", "delta": flush_text}

                for event in emitted_events:
                    if event["kind"] == "tool_call_delta":
                        tool_calls_emitted = True
                        yield event
                        continue

                    delta_text = event.get("delta", "")
                    if not delta_text:
                        continue

                    if tool_context is not None and tool_context.stop_buffer_disabled:
                        yield {"kind": "output_text_delta", "delta": delta_text}
                        continue

                    safe_text, stop_matched = buf.push(delta_text)
                    if stop_matched:
                        if safe_text:
                            yield {"kind": "output_text_delta", "delta": safe_text}
                        _close_stream(stream, cancelled=False)
                        if not deps.uses_shared_batch_runtime:
                            store_result = _maybe_store_prompt_cache(
                                session,
                                prompt_ids,
                                generated_token_ids,
                                prompt_cache=request_prompt_cache,
                                can_store=can_store,
                                cache_finalized=_cache_finalized_for_store(stream),
                            )
                        yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
                        return
                    if safe_text:
                        yield {"kind": "output_text_delta", "delta": safe_text}

                if tool_context is not None and tool_context.pending_error is not None:
                    _close_stream(stream, cancelled=True)
                    yield {
                        "kind": "failed",
                        "code": tool_context.pending_error.code,
                        "message": tool_context.pending_error.message,
                        "retryable": tool_context.pending_error.retryable,
                    }
                    return

                if orchard_eos or finish_reason is not None:
                    if tool_context is None or not tool_context.stop_buffer_disabled:
                        flush_text = buf.flush()
                        if flush_text:
                            yield {"kind": "output_text_delta", "delta": flush_text}

                    if tool_context is not None:
                        final_error = finalize_tool_calling(tool_context, terminal_kind="completed")
                        for event in tool_context.take_pending_events():
                            if event["kind"] == "tool_call_delta":
                                tool_calls_emitted = True
                            yield event
                        if final_error is not None:
                            _close_stream(stream, cancelled=True)
                            yield {
                                "kind": "failed",
                                "code": final_error.code,
                                "message": final_error.message,
                                "retryable": final_error.retryable,
                            }
                            return

                    if not deps.uses_shared_batch_runtime:
                        store_result = _maybe_store_prompt_cache(
                            session,
                            prompt_ids,
                            generated_token_ids,
                            prompt_cache=request_prompt_cache,
                            can_store=can_store,
                        )
                    if tool_calls_emitted:
                        yield _completed_event(
                            "FINISH_REASON_TOOL_CALLS",
                            input_tokens,
                            output_tokens,
                        )
                    elif orchard_eos or finish_reason == "stop":
                        yield _completed_event("FINISH_REASON_STOP", input_tokens, output_tokens)
                    else:
                        yield _completed_event("FINISH_REASON_LENGTH", input_tokens, output_tokens)
                    return

            drained_prefill = bool(progress_queue)
            yield from _drain_prefill_progress(
                progress_queue,
                last_processed_tokens_out=last_prefill_processed_tokens,
            )
            finalize_prefill_probe_if_needed(drained_prefill)
            if tool_context is None or not tool_context.stop_buffer_disabled:
                flush_text = buf.flush()
                if flush_text:
                    yield {"kind": "output_text_delta", "delta": flush_text}
            if cancel_event.is_set():
                if tool_context is not None:
                    finalize_tool_calling(tool_context, terminal_kind="cancelled")
                    for event in tool_context.take_pending_events():
                        if event["kind"] == "tool_call_delta":
                            tool_calls_emitted = True
                        yield event
                yield cancelled_event()
            else:
                if tool_context is not None:
                    final_error = finalize_tool_calling(tool_context, terminal_kind="completed")
                    for event in tool_context.take_pending_events():
                        if event["kind"] == "tool_call_delta":
                            tool_calls_emitted = True
                        yield event
                    if final_error is not None:
                        yield {
                            "kind": "failed",
                            "code": final_error.code,
                            "message": final_error.message,
                            "retryable": final_error.retryable,
                        }
                        return

                if not deps.uses_shared_batch_runtime:
                    store_result = _maybe_store_prompt_cache(
                        session,
                        prompt_ids,
                        generated_token_ids,
                        prompt_cache=request_prompt_cache,
                        can_store=can_store,
                    )
                finish = "FINISH_REASON_TOOL_CALLS" if tool_calls_emitted else "FINISH_REASON_STOP"
                yield _completed_event(finish, input_tokens, output_tokens)
            return

    finally:
        if stream is not None:
            _close_stream(stream, cancelled=True)

        _emit_prefix_cache_log(
            prompt_tokens=prompt_tokens,
            lookup=lookup_result,
            store=store_result,
            final_stats=_safe_stats(getattr(session, "prefix_cache", None)),
        )
        if not deps.uses_shared_batch_runtime:
            _safe_clear_session_cache(session)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _decode_prompt(payload: bytes | str | None) -> str:
    """Decode rendered_prompt_utf8 into a string.

    Raises ``BackendError("invalid_prompt_utf8")`` on decode failure.
    """
    if payload is None:
        raise BackendError(
            "invalid_prompt_utf8",
            "rendered_prompt_utf8 is missing",
            False,
        )
    if isinstance(payload, str):
        return payload
    if isinstance(payload, (bytes, bytearray, memoryview)):
        try:
            return bytes(payload).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BackendError(
                "invalid_prompt_utf8",
                f"rendered_prompt_utf8 is not valid UTF-8: {exc}",
                False,
            ) from exc
    raise BackendError(
        "invalid_prompt_utf8",
        f"rendered_prompt_utf8 has unsupported type: {type(payload).__name__}",
        False,
    )


def _encode_prompt(tokenizer: Any, prompt_text: str) -> list[int]:
    """Encode prompt text into token IDs.

    Uses ``add_special_tokens=False`` because the controller already renders
    the final prompt (chat template, BOS, system scaffolding).  Do not change
    this without coordinating with the controller's prompt pipeline.
    """
    try:
        # WARNING: add_special_tokens must stay False — see module docstring.
        return tokenizer.encode(prompt_text, add_special_tokens=False)
    except Exception as exc:
        raise BackendError(
            "generation_failed",
            f"prompt tokenization failed: {exc}",
            False,
        ) from exc


def _build_sampler(temperature: float, top_p: float, deps: GenerationDeps) -> Any:
    """Build a sampler from request parameters."""
    kwargs: dict[str, Any] = {}
    if temperature > 0:
        kwargs["temp"] = temperature
    if 0 < top_p < 1.0:
        kwargs["top_p"] = top_p
    return deps.make_sampler(**kwargs)


def _completed_event(finish_reason: str, input_tokens: int, output_tokens: int) -> dict[str, Any]:
    """Build a terminal completed event dict."""
    return {
        "kind": "completed",
        "finish_reason": finish_reason,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "total_tokens": input_tokens + output_tokens,
        },
    }


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default
