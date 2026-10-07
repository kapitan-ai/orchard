"""Composition with actual Orchard event/tool mapping and a fake native engine."""

import json
import threading
import time
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generated.cluster.v1 import runtime_pb2
from orchard_worker_mlx.service import WorkerRuntimeServicer
from test_admission import encode, render, request_for
from test_admission import profile as profile
from test_tensorfold_driver import Cancellation, Checkpoints, Engine, Scheduler, job_factory

from orchard_tensorfold_http.backend import RuntimeAssets, TensorFoldBackend
from orchard_tensorfold_http.tensorfold_driver import DriverBounds, TensorFoldDriver


class Detokenizer:
    def reset(self):
        self.last_segment = ""

    def add_token(self, token):
        self.last_segment = chr(token)

    def finalize(self):
        self.last_segment = ""


class RawScheduler(Scheduler):
    reply = "opaque</think>\n\nfinal"
    reply_tokens = None

    def submit(self, job):
        # The actual FamilyRounds/GPU sampler consumes attributes, not a dict.
        if job.temperature == 0:
            assert job.sampling is None
        else:
            assert job.sampling.temperature == job.temperature
            assert 0 <= job.sampling.top_p <= 1
            assert job.sampling.top_k == 0 and job.sampling.min_p == 0
            assert type(job.sampling.seed) is int
        self.jobs.append(job)
        job.stream = SimpleNamespace(finish_reason="stop", history_checkpoints=[])
        self.active = self.engine.active_count = 1
        hit = self.checkpoints.match(job.prompt_ids)
        job.cached_tokens, cache = (0, [{"bytes": 10}]) if hit is None else (hit[0], hit[1])
        snapshot = self.engine.copy_single_cache(cache)
        self.checkpoints.insert(
            job.prompt_ids[: job.history_len], snapshot, last_prompt=job.prompt_ids
        )
        tokens = encode(self.reply) if self.reply_tokens is None else self.reply_tokens
        for begin in range(0, len(tokens), 64):
            job.chunks.put(tokens[begin : begin + 64])
        job.chunks.put(None)
        self.active = self.engine.active_count = 0
        job.done.set()


@pytest.fixture
def runtime(profile):
    trace = SimpleNamespace(settles=0, settle=True, quarantines=0)
    bounds = DriverBounds(
        total_budget_bytes=100,
        working_bytes=20,
        workspace_bytes=10,
        checkpoint_budget_bytes=20,
        checkpoint_slots=1,
        max_cache_leases=5,
        max_cache_layers=2,
        max_buffer_chunks=20,
        max_buffer_tokens=1000,
        max_chunk_tokens=64,
        vocabulary_size=256,
        max_input_tokens=10000,
        max_output_tokens=1000,
        max_context_tokens=11000,
        poll_seconds=0.001,
        request_seconds=10,
        cancel_seconds=0.05,
        settlement_seconds=0.05,
    )

    def settle(_):
        trace.settles += 1
        return trace.settle

    def load(_path, _profile, quarantine):
        def fail():
            trace.quarantines += 1
            quarantine()

        driver = TensorFoldDriver(
            Engine(),
            scheduler_factory=RawScheduler,
            job_factory=job_factory,
            checkpoint_factory=Checkpoints,
            cancellation_factory=Cancellation,
            bounds=bounds,
            copy_bounds=lambda _: (10, 5),
            copy_settlement=lambda *a: True,
            request_settlement=settle,
            on_quarantine=fail,
            eos_ids=frozenset({255}),
        )
        tokenizer = SimpleNamespace(detokenizer=Detokenizer())
        session = SimpleNamespace(
            model=object(),
            tokenizer=tokenizer,
            eos_token_ids=(),
            decode_cancel_stride=1,
            prefill_step_size=1,
            prefix_cache=None,
            tool_calling={"supported": False},
        )

        def sampling(_prompt, temperature, top_p):
            return (
                None
                if temperature == 0
                else SimpleNamespace(temperature=temperature, top_p=top_p, seed=1, top_k=0, min_p=0)
            )

        trace.assets = RuntimeAssets(session, driver, render, encode, sampling)
        return trace.assets

    backend = TensorFoldBackend(profile, load, enabled=True, wall_clock=lambda: 1000)
    backend.load_model(model_id=profile.model_id, version=profile.version, model_path="owned")
    trace.backend = backend
    return trace


def generate(runtime, request=None):
    backend = runtime.backend
    request = request or request_for(backend.profile, backend.incarnation)
    service = WorkerRuntimeServicer(backend, memory_sampler=lambda: None)
    context = Mock()
    context.add_callback.return_value = True
    return service.Generate(request, context)


def kinds(events):
    return [event.WhichOneof("event") for event in events]


def test_default_off_requires_explicit_constructed_backend(profile):
    with pytest.raises(BackendError, match="disabled"):
        TensorFoldBackend(profile, Mock())


def test_exact_raw_spelling_survives_real_orchard_pipeline(runtime):
    events = list(generate(runtime))
    assert "".join(
        e.output_text_delta.delta for e in events if e.HasField("output_text_delta")
    ) == ("opaque</think>\n\nfinal")
    assert kinds(events)[-1] == "completed"
    assert runtime.settles == 1 and runtime.assets.driver.settled
    assert (
        runtime.backend.health()["ready"] and runtime.backend.status()["active_request_count"] == 0
    )


def test_greedy_sampling_uses_provider_none_convention(runtime):
    request = request_for(runtime.backend.profile, runtime.backend.incarnation)
    request.params.temperature = 0
    assert kinds(list(generate(runtime, request)))[-1] == "completed"
    assert runtime.assets.driver.scheduler.jobs[0].sampling is None


@pytest.mark.parametrize("tokens,expected", [([65, 255], "A"), ([255], "")])
def test_terminal_eos_spelling_is_suppressed_with_token_accounting(runtime, tokens, expected):
    runtime.assets.session.eos_token_ids = (255,)
    runtime.assets.driver.scheduler.reply_tokens = tokens
    detokenizer = runtime.assets.session.tokenizer.detokenizer
    detokenizer.add_token = Mock(wraps=detokenizer.add_token)
    events = list(generate(runtime))
    assert "".join(e.output_text_delta.delta for e in events) == expected
    assert events[-1].WhichOneof("event") == "completed"
    assert events[-1].completed.usage.output_tokens == len(tokens)
    assert all(call.args != (255,) for call in detokenizer.add_token.call_args_list)
    assert runtime.assets.driver.settled and runtime.backend.health()["ready"]


def test_eos_finalizes_pending_multibyte_spelling(runtime):
    class PendingUnicode(Detokenizer):
        def add_token(self, token):
            assert token == 65
            self.last_segment = ""

        def finalize(self):
            self.last_segment = "é"

    runtime.assets.session.tokenizer.detokenizer = PendingUnicode()
    runtime.assets.session.eos_token_ids = (255,)
    runtime.assets.driver.scheduler.reply_tokens = [65, 255]
    events = list(generate(runtime))
    assert "".join(e.output_text_delta.delta for e in events) == "é"
    assert events[-1].WhichOneof("event") == "completed" and runtime.assets.driver.settled


def test_tokens_after_eos_freeze_incarnation(runtime):
    runtime.assets.session.eos_token_ids = (255,)
    runtime.assets.driver.scheduler.reply_tokens = [65, 255, 66]
    events = list(generate(runtime))
    assert events[-1].WhichOneof("event") == "failed"
    assert not runtime.backend.health()["ready"]


def test_shutdown_during_load_denies_late_start_and_keeps_late_assets(runtime):
    entered, release = threading.Event(), threading.Event()
    driver = Mock(quarantined=False)
    assets = RuntimeAssets(SimpleNamespace(), driver, render, encode, Mock())

    def load(*_args):
        entered.set()
        assert release.wait(timeout=1)
        return assets

    backend = TensorFoldBackend(runtime.backend.profile, load, enabled=True)
    failures = []

    def run_load():
        try:
            backend.load_model(
                model_id=backend.profile.model_id,
                version=backend.profile.version,
                model_path="owned",
            )
        except BackendError as exc:
            failures.append(exc.code)

    thread = threading.Thread(target=run_load)
    thread.start()
    assert entered.wait(timeout=1)
    try:
        with pytest.raises(BackendError, match="uncertain"):
            backend.shutdown()
    finally:
        release.set()
        thread.join(timeout=1)
    assert not thread.is_alive() and failures == ["model_load_failed"]
    driver.start.assert_not_called()
    assert backend._assets is assets and not backend.health()["ready"]
    assert not backend.tensorfold_profile_admission()


def test_terminal_is_not_visible_until_positive_settlement(runtime):
    stream = generate(runtime)
    saw_terminal = False
    for event in stream:
        if event.WhichOneof("event") in {"completed", "failed"}:
            saw_terminal = True
            assert runtime.settles == 1
            assert runtime.assets.driver.settled
    assert saw_terminal


def test_failed_native_settlement_quarantines_before_terminal(runtime):
    runtime.settle = False
    events = list(generate(runtime))
    assert kinds(events)[-1] == "failed" and "completed" not in kinds(events)
    assert events[-1].failed.code == "runtime_quarantined"
    assert not runtime.backend.health()["ready"]
    assert runtime.assets.driver._custody.snapshot().held_bytes == 10
    with pytest.raises(BackendError, match="reaping"):
        runtime.backend.start_generation()


def test_missing_or_stale_projection_never_submits(runtime):
    request = request_for(runtime.backend.profile, "stale")
    events = list(generate(runtime, request))
    assert kinds(events) == ["failed"]
    assert not runtime.assets.driver.scheduler.jobs
    assert runtime.backend.health()["ready"]
    request.tensorfold_history_projection_json = b""
    assert kinds(list(generate(runtime, request))) == ["failed"]
    assert not runtime.assets.driver.scheduler.jobs


def test_c1_capacity_rejects_parallel_work_and_unload(runtime):
    runtime.backend.start_generation()
    with pytest.raises(BackendError, match="C1"):
        runtime.backend.start_generation()
    with pytest.raises(BackendError, match="active"):
        runtime.backend.unload_model()
    runtime.backend.finish_generation()
    assert runtime.backend.status()["active_request_count"] == 0


def test_deadline_watchdog_freezes_stalled_consumer_without_another_pull(runtime):
    request = request_for(runtime.backend.profile, runtime.backend.incarnation)
    request.deadline_unix_ms = 1000030
    stream = generate(runtime, request)
    next(stream)
    until = time.monotonic() + 0.5
    while runtime.backend.health()["ready"] and time.monotonic() < until:
        threading.Event().wait(0.005)
    assert not runtime.backend.health()["ready"]
    assert runtime.assets.driver.quarantined
    stream.close()
    assert runtime.backend.status()["active_request_count"] == 0
    assert runtime.assets.driver._custody.snapshot().held_bytes == 10


def test_disconnect_after_delta_keeps_custody_and_denies_reuse(runtime):
    stream = generate(runtime)
    next(stream)
    stream.close()
    assert not runtime.backend.health()["ready"]
    assert runtime.assets.driver._custody.snapshot().held_bytes == 10


def test_raw_accumulation_bound_stops_hidden_tool_buffer_growth(runtime):
    runtime.backend.profile = replace(
        runtime.backend.profile, max_output_bytes=8, max_event_bytes=8
    )
    events = list(generate(runtime))
    assert kinds(events)[-1] == "failed" and "completed" not in kinds(events)
    assert not runtime.backend.health()["ready"]


def test_real_tool_context_maps_calls_and_retains_natural_continuation(runtime):
    tools = [{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}]
    tokenizer = runtime.assets.session.tokenizer
    tokenizer.tool_call_start, tokenizer.tool_call_end = "<tool_call>", "</tool_call>"
    tokenizer.tool_parser = lambda _raw, _tools: {"name": "read", "arguments": {}}
    runtime.assets.session.tool_calling = {"supported": True, "parser_type": "synthetic"}
    runtime.assets.driver.scheduler.reply = (
        "opaque</think>\n\n<tool_call><function=read></function></tool_call>"
    )
    first = request_for(runtime.backend.profile, runtime.backend.incarnation, tools=tools)
    events = list(generate(runtime, first))
    calls = [e.tool_call_delta for e in events if e.HasField("tool_call_delta")]
    assert len(calls) == 1 and events[-1].completed.finish_reason == 3
    call = calls[0]
    delta = json.loads(call.delta_json)
    assert delta["function"] == {"name": "read", "arguments_delta": "{}"}
    messages = [
        {"role": "user", "content": "test"},
        {
            "role": "assistant",
            "content": "opaque</think>\n\n",
            "tool_calls": [
                {
                    "id": call.tool_call_id,
                    "type": "function",
                    "function": {"name": "read", "arguments": "{}"},
                }
            ],
        },
        {"role": "tool", "tool_call_id": call.tool_call_id, "content": "approved result"},
    ]
    second = request_for(
        runtime.backend.profile, runtime.backend.incarnation, messages=messages, tools=tools
    )
    runtime.assets.driver.scheduler.reply = "final"
    assert kinds(list(generate(runtime, second)))[-1] == "completed"
    assert len(runtime.assets.driver.scheduler.jobs) == 2 and runtime.settles == 2
    assert json.loads(second.tensorfold_history_projection_json)["messages"] == messages


def test_tokenizer_exception_has_constant_failure_without_reuse(runtime):
    runtime.assets.session.tokenizer.detokenizer.add_token = Mock(
        side_effect=ValueError("private-text")
    )
    events = list(generate(runtime))
    assert kinds(events)[-1] == "failed"
    assert "private-text" not in str(events[-1]) and not runtime.backend.health()["ready"]


def test_stock_worker_rejects_projection_before_backend_admission(runtime):
    from orchard_worker_mlx.backends import StubBackend

    backend = StubBackend()
    backend.start_generation = Mock(side_effect=AssertionError("must not admit"))
    service = WorkerRuntimeServicer(backend, memory_sampler=lambda: None)
    events = list(service.Generate(request_for(runtime.backend.profile), Mock()))
    assert kinds(events) == ["failed"]
    assert events[0].failed.code == "unsupported_history_projection"
    backend.start_generation.assert_not_called()


def test_current_proto_serialization_keeps_projection_separate_from_metadata(runtime):
    original = request_for(runtime.backend.profile, runtime.backend.incarnation)
    request = runtime_pb2.ExecuteInferenceRequest.FromString(original.SerializeToString())
    assert request.tensorfold_history_projection_json == original.tensorfold_history_projection_json
    assert not request.metadata_json
    assert kinds(list(generate(runtime, request)))[-1] == "completed"


def test_caller_mutation_after_first_event_cannot_change_native_job(runtime):
    request = request_for(runtime.backend.profile, runtime.backend.incarnation)
    stream = generate(runtime, request)
    next(stream)
    request.params.max_output_tokens = 1
    request.params.temperature = 0
    request.tensorfold_history_projection_json = b"{}"
    assert kinds(list(stream))[-1] == "completed"
    job = runtime.assets.driver.scheduler.jobs[0]
    assert job.max_tokens == 100 and job.temperature == 1


def test_normal_unload_retires_old_incarnation_without_process_reap(runtime):
    old = runtime.backend.incarnation
    assert kinds(list(generate(runtime)))[-1] == "completed"
    runtime.backend.unload_model()
    assert runtime.assets.driver.normal_closed and runtime.assets.driver.retired
    assert not runtime.assets.driver._custody.snapshot().reaped
    assert runtime.backend.incarnation == "" and not runtime.backend.status()["loaded"]
    runtime.backend.load_model(
        model_id=runtime.backend.profile.model_id,
        version=runtime.backend.profile.version,
        model_path="owned",
    )
    assert runtime.backend.incarnation != old
    assert kinds(list(generate(runtime)))[-1] == "completed"
