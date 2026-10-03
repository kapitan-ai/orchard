"""Opt-in, instrumented real-runtime evidence for #409; not ADR 0028 approval."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

import pytest

_BUNDLE_ENV = "ORCHARD_MLX_LIFECYCLE_BUNDLE"
_BUNDLE_SHA256 = "d30ebd70f4a436c152939ec8f4c798c8a2096fb210445781833e4bf4e60f5dd4"
_MLX_LM_REVISION = "ab1806e8f5d6aa035973af194a1b9198ab4754dc"


@pytest.mark.skipif(not os.environ.get(_BUNDLE_ENV), reason=f"Set {_BUNDLE_ENV} to opt in")
def test_real_partial_prefill_cancel_preserves_peer() -> None:
    """SPEC request cancellation, worker-local cleanup, and ADR 0028 evidence boundaries."""
    result = subprocess.run(
        [sys.executable, __file__, os.environ[_BUNDLE_ENV]],
        env={**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout)
    print(result.stderr)


@pytest.mark.parametrize("optimize", ["1", "2"])
def test_optimized_child_fails_before_mlx_import(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, optimize: str
) -> None:
    monkeypatch.setenv("PYTHONOPTIMIZE", optimize)
    # The import tripwire makes even the unsafe original fail without touching MLX or a model.
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            """
import builtins
import runpy
import sys

original_import = builtins.__import__
def guarded_import(name, *args, **kwargs):
    if name.split('.')[0] in {'mlx', 'mlx_lm', 'orchard_worker_mlx'}:
        raise RuntimeError('MLX_IMPORT_ATTEMPT')
    return original_import(name, *args, **kwargs)

builtins.__import__ = guarded_import
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
""",
            __file__,
            str(tmp_path),
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 1
    assert result.stderr.strip() == "MLX lifecycle qualification requires Python optimization off"
    assert "MLX_IMPORT_ATTEMPT" not in result.stdout + result.stderr


def _wait_until(predicate: Any, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("lifecycle observation deadline expired")
        time.sleep(0.001)


def _bundle_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        assert stat.S_ISREG(mode), "bundle must contain only directories and regular files"
        digest.update(path.relative_to(root).as_posix().encode())
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def _qualify(bundle: Path) -> None:
    if sys.flags.optimize:
        raise SystemExit("MLX lifecycle qualification requires Python optimization off")

    import importlib.metadata

    import mlx.core as mx

    from orchard_worker_mlx import generation
    from orchard_worker_mlx.backends import MLXBackend
    from orchard_worker_mlx.generated.cluster.v1 import common_pb2, runtime_pb2
    from orchard_worker_mlx.model_loader import (
        GenerationRuntimeConfig,
        PrefixCacheLoadConfig,
        load_manifest,
    )

    assert sys.platform == "darwin" and mx.metal.is_available()
    assert _bundle_digest(bundle) == _BUNDLE_SHA256
    direct_url = json.loads(importlib.metadata.distribution("mlx-lm").read_text("direct_url.json"))
    assert direct_url["vcs_info"]["commit_id"] == _MLX_LM_REVISION
    assert importlib.metadata.version("mlx") == "0.32.2"
    assert importlib.metadata.version("transformers") == "5.12.1"
    manifest = load_manifest(bundle)
    backend = MLXBackend(
        generation_config=GenerationRuntimeConfig(mode="batch", max_concurrent_generations=2),
        prefix_cache_config=PrefixCacheLoadConfig(mode="disabled"),
    )
    load_started = time.monotonic()
    backend.load_model(model_id=manifest.model_id, version=manifest.version, model_path=str(bundle))
    load_seconds = time.monotonic() - load_started
    runtime = backend._batch_runtime
    session = backend._session
    generator = runtime._batch_generator
    assert generator.__class__.__module__.startswith("mlx_lm.")
    first_step = threading.Event()
    release_first_step = threading.Event()
    cancelled = threading.Event()
    cancelled_done = threading.Event()
    events: list[list[dict[str, Any]]] = [[], []]
    errors: list[str] = []
    overlap: list[dict[str, Any]] = []
    row_observations: list[dict[str, Any]] = []
    token_responses: dict[int, list[int]] = {}
    timings: dict[str, float] = {}
    threads: list[threading.Thread] = []

    # Fix prompts, IDs, limits, and semantic acceptance before any measured generation.
    prompts = ["Count: " + "1 " * 1100, "The capital of France is"]
    prompt_ids = [session.tokenizer.encode(text, add_special_tokens=False) for text in prompts]
    assert len(prompt_ids[0]) > session.prefill_step_size
    requests = [
        runtime_pb2.ExecuteInferenceRequest(
            request_id=f"lifecycle-{index}",
            model_id=manifest.model_id,
            version=manifest.version,
            prompt_token_ids=ids,
            input_tokens=len(ids),
            return_token_ids=True,
            params=common_pb2.GenerationParams(max_output_tokens=8, temperature=0.0),
        )
        for index, ids in enumerate(prompt_ids)
    ]
    print(json.dumps({"predeclared_peer_prefix": "Paris", "prompt_ids": prompt_ids}), flush=True)

    original_realign = runtime._realign_batch_generator_rows
    original_progress = runtime._apply_prompt_responses
    original_response = runtime._apply_batch_response
    original_row = generation._realign_batch_row_state

    def realign(rows: Any) -> None:
        if not first_step.is_set():
            # Pause before the first real next(), so the peer can enter the pending registry.
            paused = time.monotonic()
            first_step.set()
            if not release_first_step.wait(5.0):
                raise AssertionError("initial batch barrier was not released")
            timings["initial_barrier_seconds"] = time.monotonic() - paused
        original_realign(rows)

    def progress(responses: Any) -> bool:
        result = original_progress(responses)
        with runtime._cv:
            states = list(runtime._active_by_uid.values())
            partial = [
                s
                for s in states
                if s.request_id == 0
                and s.last_prefill_progress is not None
                and 0 < s.last_prefill_progress[0] < s.last_prefill_progress[1]
            ]
            if len(states) != 2 or not partial or overlap:
                return result
            assert all(not s.closed and not s.done for s in states)
            overlap.append(
                {
                    "request_uids": {s.request_id: s.uid for s in states},
                    "progress": {s.uid: s.last_prefill_progress for s in states},
                    "actual_batch_uids": {
                        name: list(getattr(getattr(generator, name, None), "uids", []))
                        for name in ("_prompt_batch", "_generation_batch")
                    },
                }
            )
        # Real progress has been applied, but its next() token responses have not been applied.
        # Hold only until the cancelled consumer terminalizes, then let real inference drain.
        paused = time.monotonic()
        cancelled.set()
        if not cancelled_done.wait(2.0):
            raise AssertionError("cancelled consumer did not terminalize")
        timings["cancel_barrier_seconds"] = time.monotonic() - paused
        timings["drain_started"] = time.monotonic()
        return result

    def response(value: Any) -> bool:
        token_responses.setdefault(value.uid, []).append(value.token)
        return original_response(value)

    def row(batch: Any, rows: Any) -> bool:
        uids = list(getattr(batch, "uids", []))
        samplers = getattr(batch, "samplers", [])
        processors = getattr(batch, "logits_processors", [])
        before = [
            {
                "uid": uid,
                "registered": uid in rows,
                "sampler_matches": i < len(samplers) and samplers[i] is rows[uid][0],
                "processor_type": type(processors[i]).__name__
                if i < len(processors)
                else "missing",
                "processors_empty": i < len(processors) and processors[i] == [],
                "registered_processors_empty": rows[uid][1] == [],
            }
            for i, uid in enumerate(uids)
            if uid in rows
        ]
        drifted = original_row(batch, rows)
        if drifted:
            row_observations.append(
                {
                    "before": before,
                    "before_uids": uids,
                    "after_uids": list(batch.uids),
                    "after_processors_empty": all(p == [] for p in batch.logits_processors),
                    "processor_identity_changed": [
                        i >= len(processors) or processors[i] is not p
                        for i, p in enumerate(batch.logits_processors)
                    ],
                    "after_samplers_match": all(
                        batch.samplers[i] is rows[uid][0]
                        for i, uid in enumerate(uids)
                        if uid in rows
                    ),
                }
            )
        return drifted

    def run(index: int, cancel: threading.Event) -> None:
        try:
            events[index].extend(backend.generate(requests[index], cancel))
        except Exception as exc:
            errors.append(repr(exc))
        finally:
            if index == 0:
                cancelled_done.set()

    def clean() -> bool:
        with runtime._cv:
            return (
                not runtime._active_by_uid
                and not runtime._requests_by_id
                and not runtime._pending_by_id
                and not runtime._pending_request_ids
                and not runtime._active_detokenizer_ids
                and not runtime._prefill_attribution_by_insert_set_id
            )

    try:
        with pytest.MonkeyPatch.context() as patch:
            patch.setattr(runtime, "_realign_batch_generator_rows", realign)
            patch.setattr(runtime, "_apply_prompt_responses", progress)
            patch.setattr(runtime, "_apply_batch_response", response)
            patch.setattr(generation, "_realign_batch_row_state", row)
            started = time.monotonic()
            threads.append(threading.Thread(target=run, args=(0, cancelled), daemon=True))
            threads[0].start()
            if not first_step.wait(5.0):
                raise AssertionError("first batch step was not reached")
            threads.append(threading.Thread(target=run, args=(1, threading.Event()), daemon=True))
            threads[1].start()
            _wait_until(lambda: len(runtime._requests_by_id) == 2)
            release_first_step.set()
            for thread in threads:
                thread.join(15.0)
                assert not thread.is_alive()
            assert not errors, errors
            assert overlap, "no actual two-UID partial-prefill overlap observed"
            assert set(overlap[0]["request_uids"]) == {0, 1}
            assert any(
                set(uids) == set(overlap[0]["request_uids"].values())
                for uids in overlap[0]["actual_batch_uids"].values()
            ), "runtime registries alone do not prove an actual shared upstream batch"
            assert [e["kind"] for e in events[0] if e["kind"] in {"completed", "failed"}] == [
                "failed"
            ]
            assert events[0][-1]["code"] == "cancelled"
            assert [e["kind"] for e in events[1] if e["kind"] in {"completed", "failed"}] == [
                "completed"
            ]
            text = "".join(e["delta"] for e in events[1] if e["kind"] == "output_text_delta")
            assert text.startswith("Paris"), text
            peer_tokens = [
                token for e in events[1] if e["kind"] == "token_delta" for token in e["token_ids"]
            ]
            assert peer_tokens == token_responses[overlap[0]["request_uids"][1]]
            assert len(peer_tokens) == 8
            assert events[1][-1]["finish_reason"] == "FINISH_REASON_LENGTH"
            assert events[1][-1]["usage"] == {
                "input_tokens": len(prompt_ids[1]),
                "output_tokens": len(peer_tokens),
                "total_tokens": len(prompt_ids[1]) + len(peer_tokens),
            }
            _wait_until(clean)
            timings["drain_and_peer_seconds"] = time.monotonic() - timings.pop("drain_started")
            assert runtime._batch_generator is generator
            assert runtime._reset_requested is None
            assert not runtime._closed_batch_generator_refs
            recovery = list(backend.generate(requests[1], threading.Event()))
            assert [e["kind"] for e in recovery if e["kind"] in {"completed", "failed"}] == [
                "completed"
            ]
            assert "".join(
                e["delta"] for e in recovery if e["kind"] == "output_text_delta"
            ).startswith("Paris")
            assert recovery[-1]["usage"] == events[1][-1]["usage"]
            _wait_until(clean)
            assert runtime._batch_generator is generator
            assert runtime._reset_requested is None
            assert not runtime._closed_batch_generator_refs
            assert row_observations, "row-state observation did not execute"
            print(
                json.dumps(
                    {
                        "bundle_sha256": _BUNDLE_SHA256,
                        "load_seconds": load_seconds,
                        "instrumented_seconds": time.monotonic() - started,
                        "timings": timings,
                        "overlap": overlap,
                        "events": events,
                        "recovery": recovery,
                        "row_observations": row_observations,
                        "registries_empty_before_close": clean(),
                        "same_generator": True,
                    }
                ),
                flush=True,
            )
    finally:
        release_first_step.set()
        cancelled.set()
        for thread in threads:
            thread.join(5.0)
        backend.unload_model()
    assert not backend.status()["loaded"]
    assert not runtime._pump.is_alive() and not runtime._watchdog.is_alive()
    assert runtime._session is None and runtime._batch_generator is None
    assert _bundle_digest(bundle) == _BUNDLE_SHA256
    print(json.dumps({"unloaded": True, "runtime_threads_stopped": True}), flush=True)


if __name__ == "__main__":
    _qualify(Path(sys.argv[1]).resolve(strict=True))
