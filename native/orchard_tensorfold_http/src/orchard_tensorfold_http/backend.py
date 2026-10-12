"""Default-off Worker Backend with Orchard's existing output/tool event pipeline."""

import json
import logging
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any
from uuid import uuid4

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generation import GenerationDeps, generate_events

from orchard_tensorfold_http.admission import AdmittedHistory, ExperimentProfile, admit_history
from orchard_tensorfold_http.tensorfold_driver import DriverError, TensorFoldDriver

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RuntimeAssets:
    session: Any
    driver: TensorFoldDriver
    render: Callable[..., str]
    encode: Callable[[str], list[int]]
    make_sampling: Callable[[tuple[int, ...], float, float], Any]


class TensorFoldBackend:
    """One explicit frozen profile, one loaded incarnation and one request.

    A separate executable injects this backend into WorkerRuntimeServicer. It
    does not replace the default backend or derive admission from capabilities.
    Successful terminals are withheld until the driver has positively settled;
    failures install persistent quarantine before releasing the outer slot.
    """

    accepts_tensorfold_history_projection = True

    def __init__(
        self,
        profile: ExperimentProfile,
        load_assets: Callable[[str, ExperimentProfile, Callable[[], None]], RuntimeAssets],
        *,
        enabled: bool = False,
        wall_clock: Callable[[], float] = time.time,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ):
        if enabled is not True:
            raise BackendError("experiment_disabled", "TensorFold experiment is disabled", False)
        self.profile = profile
        self._loader = load_assets
        self._wall_clock, self._monotonic_clock = wall_clock, monotonic_clock
        self._lock = threading.RLock()
        self._assets: RuntimeAssets | None = None
        self._incarnation = ""
        self._active = False
        self._loading = False
        self._closing = False
        self._quarantined = False

    @property
    def incarnation(self) -> str:
        with self._lock:
            return self._incarnation

    def _quarantine(self) -> None:
        with self._lock:
            self._quarantined = True

    def _available(self) -> None:
        if self._closing:
            raise BackendError("runtime_stopping", "owned runtime is stopping", False)
        if self._quarantined or (self._assets and self._assets.driver.quarantined):
            raise BackendError("runtime_quarantined", "owned runtime requires reaping", False)

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "loaded": self._assets is not None,
                "active_request_count": int(self._active or self._loading),
                "max_concurrency": 1,
            }

    def health(self) -> dict[str, Any]:
        with self._lock:
            bad = self._quarantined or bool(self._assets and self._assets.driver.quarantined)
            return {
                "ready": not bad and not self._loading and not self._closing,
                "code": "runtime_quarantined" if bad else "",
                "message": "owned runtime requires reaping" if bad else "",
            }

    def tensorfold_profile_admission(self) -> bytes:
        """Offer one explicit loaded binding over the owned Worker channel."""
        with self._lock:
            if (
                self._assets is None
                or self._quarantined
                or self._closing
                or self._loading
                or self._assets.driver.quarantined
            ):
                return b""
            return json.dumps(self.profile.binding(self._incarnation), sort_keys=True).encode()

    def shutdown(self) -> None:
        """Close this owned process's driver without granting later admission."""
        with self._lock:
            self._closing = True
            assets = self._assets
            if self._loading:
                self._quarantine()
                raise BackendError(
                    "runtime_quarantined", "owned load/shutdown remained uncertain", False
                )
        if assets is not None:
            try:
                assets.driver.shutdown()
            except Exception:
                self._quarantine()
                raise BackendError(
                    "runtime_quarantined", "owned shutdown remained uncertain", False
                ) from None

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        with self._lock:
            self._available()
            if (model_id, version) != (self.profile.model_id, self.profile.version):
                raise BackendError(
                    "model_identity_mismatch", "model is outside frozen profile", False
                )
            if self._active or self._loading or self._assets is not None:
                raise BackendError("runtime_busy", "runtime cannot load another model", True)
            self._loading = True
        try:
            assets = self._loader(model_path, self.profile, self._quarantine)
            with self._lock:
                # Keep late assets in custody even if shutdown won the race.
                self._assets = assets
                self._available()
                # Serialize start against shutdown's closing transition.
                assets.driver.start()
                self._available()
                self._assets = assets
                self._incarnation = uuid4().hex
        except BaseException:
            self._quarantine()
            raise BackendError(
                "model_load_failed", "experimental model load failed", False
            ) from None
        finally:
            with self._lock:
                self._loading = False

    def unload_model(self) -> None:
        with self._lock:
            self._available()
            if self._active or self._loading:
                raise BackendError("runtime_busy", "runtime has active work", True)
            assets = self._assets
            self._loading = True
        try:
            if assets is not None:
                assets.driver.shutdown()
            with self._lock:
                self._assets = None
                self._incarnation = ""
        except BaseException:
            self._quarantine()
            raise BackendError(
                "runtime_quarantined", "runtime unload did not settle", False
            ) from None
        finally:
            with self._lock:
                self._loading = False

    def start_generation(self) -> None:
        with self._lock:
            self._available()
            if self._assets is None:
                raise BackendError("model_not_loaded", "model is not loaded", False)
            if self._active or self._loading:
                raise BackendError("runtime_busy", "runtime is at C1 capacity", True)
            self._active = True

    def finish_generation(self) -> None:
        with self._lock:
            if self._assets and not self._assets.driver.settled:
                self._quarantine()
            self._active = False

    def record_fingerprint(self, _: str) -> None:
        raise BackendError("unsupported_cache_affinity", "cache affinity is unsupported", False)

    def get_fingerprints(self) -> list[str]:
        return []

    def prefix_cache_status(self) -> dict[str, Any]:
        return {"status_code": "unavailable", "status_message": "experiment status is internal"}

    def score_prefix_cache(self, **_: Any) -> dict[str, Any]:
        return {
            "status_code": "unsupported_version",
            "status_message": "experiment scoring is disabled",
            "resident_fingerprint_match": False,
            "score_tier": "unknown",
            "session_started_unix_ms": 0,
        }

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        with self._lock:
            self._available()
            assets, incarnation = self._assets, self._incarnation
        if assets is None:
            raise BackendError("model_not_loaded", "model is not loaded", False)
        envelope_limit = 4 * self.profile.max_projection_bytes + 8 * self.profile.max_input_tokens
        try:
            if request.ByteSize() > envelope_limit:
                raise BackendError(
                    "invalid_history_projection", "request envelope exceeds profile", False
                )
            snapshot = type(request)()
            snapshot.CopyFrom(request)
            request = snapshot
            admitted = admit_history(
                request,
                profile=self.profile,
                incarnation=incarnation,
                render=assets.render,
                encode=assets.encode,
                wall_seconds=self._wall_clock(),
                monotonic_seconds=self._monotonic_clock(),
            )
        except BackendError as exc:
            # Admission reasons are fixed literals, so this never logs request content.
            logger.warning(
                "tensorfold admission rejected request_id=%s code=%s reason=%s",
                request.request_id,
                exc.code,
                exc.message,
            )
            raise
        done = threading.Event()

        def expire() -> None:
            if not done.wait(max(0, admitted.deadline_monotonic - self._monotonic_clock())):
                with self._lock:
                    if done.is_set():
                        return
                    self._quarantine()
                cancel_event.set()
                assets.driver.quarantine()
                assets.driver.cancel()

        watchdog = threading.Thread(target=expire, name="orchard-tensorfold-deadline", daemon=True)
        watchdog.start()
        terminal: dict[str, Any] | None = None
        output_bytes = 0
        completed = False
        deps = GenerationDeps(
            stream_generate=lambda *_args, **_kwargs: self._responses(
                assets, admitted, request, cancel_event
            ),
            make_sampler=lambda **_kwargs: None,
            uses_shared_batch_runtime=True,
            supports_orchard_stop_sequences=False,
        )
        iterator = generate_events(assets.session, request, cancel_event, deps=deps)
        try:
            for event in iterator:
                with self._lock:
                    self._available()
                if event["kind"] in {"completed", "failed"}:
                    terminal = event
                    break
                delta = event.get("delta")
                if isinstance(delta, str):
                    event_bytes = len(delta.encode("utf-8"))
                elif event["kind"] == "tool_call_delta":
                    # Bound the parsed event without publishing raw provider exceptions.
                    event_bytes = len(json.dumps(event, ensure_ascii=False).encode("utf-8"))
                else:
                    event_bytes = 0
                output_bytes += event_bytes
                if (
                    event_bytes > self.profile.max_event_bytes
                    or output_bytes > self.profile.max_output_bytes
                ):
                    raise DriverError("output exceeds frozen bounds")
                yield event
            iterator.close()
            if not assets.driver.settled or assets.driver.quarantined:
                raise DriverError("provider did not positively settle")
            with self._lock:
                self._available()
                done.set()
            if terminal is None:
                raise DriverError("provider did not produce a terminal")
            completed = True
            yield terminal
        except Exception:
            self._quarantine()
            assets.driver.quarantine()
            yield {
                "kind": "failed",
                "code": "runtime_quarantined",
                "message": "experimental runtime did not establish safe completion",
                "retryable": False,
            }
        finally:
            done.set()
            watchdog.join(timeout=1)
            try:
                iterator.close()
            finally:
                if not completed:
                    self._quarantine()
                    assets.driver.quarantine()
                    assets.driver.cancel()

    def _responses(
        self,
        assets: RuntimeAssets,
        admitted: AdmittedHistory,
        request: Any,
        cancel_event: threading.Event,
    ) -> Iterator[Any]:
        """Preserve raw token spelling through the existing MLX detokenizer.

        One response of lookahead permits finalization without splitting or
        trimming reasoning. No TensorFold ChatApp/HTTP parser is involved.
        """
        detokenizer = assets.session.tokenizer.detokenizer
        detokenizer.reset()
        pending: Any = None
        raw_bytes = 0
        saw_eos = False
        eos_ids = frozenset(assets.session.eos_token_ids)
        chunks = assets.driver.generate(
            list(admitted.prompt_ids),
            admitted.history_len,
            request.params.max_output_tokens,
            request.params.temperature,
            assets.make_sampling(
                admitted.prompt_ids, request.params.temperature, request.params.top_p
            ),
            cancel_event=cancel_event,
            deadline_monotonic=admitted.deadline_monotonic,
            checkpoint_boundaries=admitted.checkpoint_boundaries,
        )
        try:
            for chunk in chunks:
                for token in chunk:
                    if saw_eos:
                        raise DriverError("provider emitted tokens after terminal EOS")
                    if token in eos_ids:
                        # TensorFold publishes EOS; Orchard's existing batch
                        # response suppresses its spelling but retains counting.
                        saw_eos = True
                        piece = ""
                    else:
                        detokenizer.add_token(token)
                        piece = detokenizer.last_segment
                    if (
                        not isinstance(piece, str)
                        or len(piece.encode("utf-8")) > self.profile.max_event_bytes
                    ):
                        raise DriverError("detokenizer output exceeds event bound")
                    raw_bytes += len(piece.encode("utf-8"))
                    if raw_bytes > self.profile.max_output_bytes:
                        raise DriverError("raw output exceeds frozen bound")
                    if pending is not None:
                        yield pending
                    pending = SimpleNamespace(token=token, text=piece, finish_reason=None)
            detokenizer.finalize()
            tail = detokenizer.last_segment
            if (
                not isinstance(tail, str)
                or len(tail.encode("utf-8")) > self.profile.max_event_bytes
            ):
                raise DriverError("detokenizer finalization exceeds event bound")
            if pending is not None:
                pending.text += tail
                if (
                    raw_bytes + len(tail.encode("utf-8")) > self.profile.max_output_bytes
                    or len(pending.text.encode("utf-8")) > self.profile.max_event_bytes
                ):
                    raise DriverError("final output exceeds frozen bounds")
                if assets.driver.completion is not None:
                    pending.finish_reason = assets.driver.completion.finish_reason
                yield pending
            elif tail:
                raise DriverError("detokenizer returned text without tokens")
        finally:
            try:
                if cancel_event.is_set():
                    # A cancelled consumer can close this stream mid-chunk. Drain
                    # through the driver's bounded settlement instead of abandoning
                    # it; the driver yields nothing further once it sees the cancel.
                    for _ in chunks:
                        pass
            finally:
                chunks.close()
