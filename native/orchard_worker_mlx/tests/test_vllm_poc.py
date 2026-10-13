from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from uuid import UUID

import pytest

from orchard_worker_mlx.backends import Backend, BackendError
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, runtime_pb2
from orchard_worker_mlx.generated.orchard.worker.v1 import worker_runtime_pb2
from orchard_worker_mlx.service import WorkerRuntimeServicer
from orchard_worker_mlx.vllm_poc import (
    MAX_INPUT_TOKENS,
    MAX_OUTPUT_TOKENS,
    MAX_TOTAL_TOKENS,
    MODEL_ID,
    MODEL_VERSION,
    SERVED_MODEL_ID,
    VLLMPocBackend,
    VLLMPocConfig,
    _QwenPocOutputParser,
)


class _FakeVLLM(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, events: list[dict[str, Any]] | None = None) -> None:
        super().__init__(("127.0.0.1", 0), _FakeVLLMHandler)
        self.events = events or []
        self.raw_events: list[bytes] | None = None
        self.send_done = True
        self.model_id = SERVED_MODEL_ID
        self.response_status = 200
        self.content_type = "text/event-stream"
        self.stall = False
        self.stall_bytes: bytes | None = None
        self.identity_drip = False
        self.request_seen = threading.Event()
        self.headers_sent = threading.Event()
        self.client_closed = threading.Event()
        self.payload: dict[str, Any] | None = None
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    @property
    def endpoint(self) -> str:
        return f"http://127.0.0.1:{self.server_port}/v1/completions"

    def __enter__(self) -> _FakeVLLM:
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


class _FakeVLLMHandler(BaseHTTPRequestHandler):
    server: _FakeVLLM

    def do_GET(self) -> None:
        if self.path != "/v1/models":
            self.send_error(404)
            return
        body = json.dumps({"data": [{"id": self.server.model_id}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.server.identity_drip:
            try:
                for byte in body:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                self.server.client_closed.set()
            return
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/v1/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        self.server.payload = json.loads(self.rfile.read(length))
        self.server.request_seen.set()
        self.send_response(self.server.response_status)
        self.send_header("Content-Type", self.server.content_type)
        self.end_headers()
        self.server.headers_sent.set()
        if self.server.response_status != 200 or self.server.content_type != "text/event-stream":
            self.wfile.write(b"rejected")
            return
        if self.server.stall_bytes is not None:
            self.wfile.write(self.server.stall_bytes)
            self.wfile.flush()
            self.connection.settimeout(3)
            try:
                if not self.connection.recv(1):
                    self.server.client_closed.set()
            except OSError:
                pass
            return
        if self.server.stall:
            try:
                while True:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                self.server.client_closed.set()
            return
        try:
            raw_events = self.server.raw_events or [
                json.dumps(event).encode() for event in self.server.events
            ]
            for event in raw_events:
                self.wfile.write(b"data: " + event + b"\n\n")
                self.wfile.flush()
            if self.server.send_done:
                self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.server.client_closed.set()

    def log_message(self, _format: str, *_args: object) -> None:
        return


def _params(
    *,
    max_output_tokens: int = 8,
    tools: list[dict[str, Any]] | None = None,
    tool_choice: Any = "auto",
) -> SimpleNamespace:
    return SimpleNamespace(
        max_output_tokens=max_output_tokens,
        temperature=1.0,
        top_p=0.95,
        stop_sequences=[],
        tools_json=json.dumps(tools or []).encode(),
        tool_choice_json=json.dumps(tool_choice).encode(),
    )


def _request(
    *,
    input_tokens: int = 3,
    max_output_tokens: int = 8,
    tools: list[dict[str, Any]] | None = None,
    tool_choice: Any = "auto",
) -> SimpleNamespace:
    return SimpleNamespace(
        model_id=MODEL_ID,
        version=MODEL_VERSION,
        rendered_prompt_utf8=b"prompt<think>\n",
        input_tokens=input_tokens,
        return_token_ids=False,
        return_logprobs=False,
        params=_params(
            max_output_tokens=max_output_tokens,
            tools=tools,
            tool_choice=tool_choice,
        ),
    )


def _provider_events(
    text_parts: list[str], *, input_tokens: int = 3, close_prompt_reasoning: bool = True
) -> list[dict[str, Any]]:
    if close_prompt_reasoning:
        text_parts = ["brief reasoning</think>", *text_parts]
    events = [{"choices": [{"text": part, "finish_reason": None}]} for part in text_parts]
    events.extend(
        [
            {"choices": [{"text": "", "finish_reason": "stop"}]},
            {
                "choices": [],
                "usage": {
                    "prompt_tokens": input_tokens,
                    "completion_tokens": 2,
                    "total_tokens": input_tokens + 2,
                },
            },
        ]
    )
    return events


def _loaded_backend(server: _FakeVLLM, model_path: Path) -> VLLMPocBackend:
    backend = VLLMPocBackend(config=VLLMPocConfig(endpoint=server.endpoint))
    backend.load_model(model_id=MODEL_ID, version=MODEL_VERSION, model_path=str(model_path))
    return backend


def _generate(backend: VLLMPocBackend, request: SimpleNamespace) -> list[dict[str, Any]]:
    backend.start_generation()
    try:
        return list(backend.generate(request, threading.Event()))
    finally:
        backend.finish_generation()


@pytest.mark.parametrize(
    "endpoint",
    [
        "https://127.0.0.1:58080/v1/completions",
        "http://localhost:58080/v1/completions",
        "http://0.0.0.0:58080/v1/completions",
        "http://127.0.0.1:58080/v1/chat/completions",
        "http://127.0.0.1:58080/v1/completions?x=1",
    ],
)
def test_config_rejects_non_exact_loopback_endpoint(endpoint: str) -> None:
    with pytest.raises(ValueError, match="loopback"):
        VLLMPocConfig(endpoint=endpoint)


def test_config_rejects_non_positive_timeouts() -> None:
    with pytest.raises(ValueError, match="positive"):
        VLLMPocConfig(request_timeout_s=0)


def test_backend_satisfies_protocol_and_reports_proof_only_capability() -> None:
    backend = VLLMPocBackend()
    assert isinstance(backend, Backend)
    assert backend.status() == {
        "loaded": False,
        "active_request_count": 0,
        "max_concurrency": 1,
        "supports_prompt_token_ids": False,
    }
    assert backend.prefix_cache_status()["status_code"] == "unavailable"
    assert backend.health()["ready"] is True
    assert (
        backend.score_prefix_cache(
            model_ref=None,
            fingerprint="unused",
            request_id="unused",
            deadline_unix_ms=0,
        )["status_code"]
        == "unavailable"
    )
    backend.record_fingerprint("unused")
    assert backend.get_fingerprints() == []


def test_load_requires_exact_tuple_path_and_provider_identity(tmp_path: Path) -> None:
    model_path = tmp_path / "model"
    model_path.mkdir()
    with _FakeVLLM() as server:
        backend = VLLMPocBackend(config=VLLMPocConfig(endpoint=server.endpoint))
        with pytest.raises(BackendError, match="accepted KAP-112 tuple"):
            backend.load_model(model_id="other", version=MODEL_VERSION, model_path=str(model_path))
        server.model_id = "other"
        with pytest.raises(BackendError) as exc_info:
            backend.load_model(
                model_id=MODEL_ID,
                version=MODEL_VERSION,
                model_path=str(model_path),
            )
        assert exc_info.value.code == "provider_identity_mismatch"


def test_load_and_generate_require_existing_loaded_model(tmp_path: Path) -> None:
    backend = VLLMPocBackend()
    with pytest.raises(BackendError) as missing_path:
        backend.load_model(
            model_id=MODEL_ID, version=MODEL_VERSION, model_path=str(tmp_path / "missing")
        )
    assert missing_path.value.code == "model_path_missing"
    with pytest.raises(BackendError) as not_loaded:
        backend.start_generation()
    assert not_loaded.value.code == "model_not_loaded"
    with pytest.raises(BackendError) as wrong_binding:
        list(backend.generate(_request(), threading.Event()))
    assert wrong_binding.value.code == "model_not_loaded"


def test_generate_rejects_request_for_different_model_version(tmp_path: Path) -> None:
    with _FakeVLLM() as server:
        backend = _loaded_backend(server, tmp_path)
        request = _request()
        request.version = "other"
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(request, threading.Event()))
    assert exc_info.value.code == "model_not_loaded"


def test_text_stream_preserves_split_legacy_reasoning_and_usage(tmp_path: Path) -> None:
    parts = list("private chain</think>Orchard Linux inference POC")
    with _FakeVLLM(_provider_events(parts, close_prompt_reasoning=False)) as server:
        backend = _loaded_backend(server, tmp_path)
        events = _generate(backend, _request())

    assert events == [
        {"kind": "output_text_delta", "delta": "private chain</think>Orchard Linux inference POC"},
        {
            "kind": "completed",
            "finish_reason": "FINISH_REASON_STOP",
            "usage": {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5},
        },
    ]
    assert server.payload == {
        "model": SERVED_MODEL_ID,
        "prompt": "prompt<think>\n",
        "max_tokens": 8,
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "presence_penalty": 0.0,
        "repetition_penalty": 1.0,
        "stop": None,
        "stream": True,
        "stream_options": {"include_usage": True},
    }


def test_length_finish_is_preserved(tmp_path: Path) -> None:
    events = [
        {"choices": [{"text": "reasoning</think>partial", "finish_reason": "length"}]},
        {
            "choices": [],
            "usage": {"prompt_tokens": 3, "completion_tokens": 8, "total_tokens": 11},
        },
    ]
    with _FakeVLLM(events) as server:
        backend = _loaded_backend(server, tmp_path)
        result = _generate(backend, _request())
    assert result[-1]["finish_reason"] == "FINISH_REASON_LENGTH"


def test_split_qwen_tool_call_is_validated_and_normalized(tmp_path: Path) -> None:
    tools = [
        {
            "type": "function",
            "function": {"name": "read", "parameters": {"type": "object"}},
        }
    ]
    raw = (
        "inspect</think><tool_call><function=read>"
        "<parameter=path>\nfixture.txt\n</parameter>"
        "<parameter=line>2</parameter></function></tool_call>"
    )
    with _FakeVLLM(_provider_events(list(raw), close_prompt_reasoning=False)) as server:
        backend = _loaded_backend(server, tmp_path)
        events = _generate(backend, _request(tools=tools, tool_choice="required"))

    assert events[0] == {"kind": "output_text_delta", "delta": "inspect</think>"}
    assert events[1]["kind"] == "tool_call_delta"
    assert UUID(events[1]["tool_call_id"].removeprefix("call_")).version == 4
    assert events[1]["delta"]["function"] == {
        "name": "read",
        "arguments_delta": '{"path":"fixture.txt","line":2}',
    }
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


def test_tool_ids_are_unique_across_calls_and_requests(tmp_path: Path) -> None:
    tools = [{"type": "function", "function": {"name": "read"}}]
    reasoning = "consider <tool_call> as text</think>"
    tool = "<tool_call><function=read></function></tool_call>"
    with _FakeVLLM(
        _provider_events([reasoning + tool + tool], close_prompt_reasoning=False)
    ) as server:
        backend = _loaded_backend(server, tmp_path)
        results = [_generate(backend, _request(tools=tools)) for _ in range(2)]

    ids = [
        event["tool_call_id"]
        for result in results
        for event in result
        if event["kind"] == "tool_call_delta"
    ]
    assert len(ids) == len(set(ids)) == 4
    assert all(UUID(value.removeprefix("call_")).version == 4 for value in ids)
    assert all(result[0] == {"kind": "output_text_delta", "delta": reasoning} for result in results)


@pytest.mark.parametrize("public_prefix", ["\n\n", " \t", "I’ll inspect the fixture first.\n\n"])
def test_public_text_prefix_is_preserved_before_typed_tool_calls(
    tmp_path: Path, public_prefix: str
) -> None:
    tools = [
        {
            "type": "function",
            "function": {"name": "read", "parameters": {"type": "object"}},
        }
    ]
    raw = (
        "inspect</think>" + public_prefix + "<tool_call><function=read>"
        "<parameter=path>fixture.txt</parameter></function></tool_call>"
    )
    with _FakeVLLM(_provider_events(list(raw), close_prompt_reasoning=False)) as server:
        backend = _loaded_backend(server, tmp_path)
        events = _generate(backend, _request(tools=tools, tool_choice="auto"))

    assert events[0] == {"kind": "output_text_delta", "delta": "inspect</think>" + public_prefix}
    assert events[1]["kind"] == "tool_call_delta"
    assert events[1]["delta"]["function"] == {
        "name": "read",
        "arguments_delta": '{"path":"fixture.txt"}',
    }
    assert events[-1]["finish_reason"] == "FINISH_REASON_TOOL_CALLS"


@pytest.mark.parametrize(
    ("text", "tool_choice", "code"),
    [
        (
            "reasoning</think><tool_call><function=read>",
            "auto",
            "tool_call_parse_failed",
        ),
        (
            "reasoning</think><tool_call><function=unknown></function></tool_call>",
            "auto",
            "tool_call_parse_failed",
        ),
        (
            "reasoning</think>plain answer",
            "required",
            "tool_choice_not_satisfied",
        ),
        (
            "reasoning</think><tool_call><function=read></function></tool_call>",
            "none",
            "tool_call_parse_failed",
        ),
        (
            "reasoning</think>answer<think>late</think>",
            "auto",
            "reasoning_parser_conformance_failed",
        ),
    ],
)
def test_parser_fails_closed(text: str, tool_choice: Any, code: str) -> None:
    parser = _QwenPocOutputParser(
        _params(
            tools=[{"type": "function", "function": {"name": "read"}}],
            tool_choice=tool_choice,
        )
    )
    for char in text:
        parser.push(char)
    with pytest.raises(BackendError) as exc_info:
        parser.finish("stop")
    assert exc_info.value.code == code


def test_parser_rejects_reasoning_without_a_final_answer() -> None:
    parser = _QwenPocOutputParser(_params())
    parser.push("reasoning</think>")

    with pytest.raises(BackendError) as exc_info:
        parser.finish("stop")

    assert exc_info.value.code == "provider_empty_output"


@pytest.mark.parametrize(
    ("input_tokens", "output_tokens", "accepted"),
    [
        (MAX_INPUT_TOKENS, MAX_OUTPUT_TOKENS, True),
        (MAX_INPUT_TOKENS + 1, 1, False),
        (1, MAX_OUTPUT_TOKENS + 1, False),
        (MAX_TOTAL_TOKENS, 1, False),
    ],
)
def test_context_envelope_boundaries(
    tmp_path: Path, input_tokens: int, output_tokens: int, accepted: bool
) -> None:
    with _FakeVLLM(_provider_events(["ok"], input_tokens=input_tokens)) as server:
        backend = _loaded_backend(server, tmp_path)
        if accepted:
            assert (
                _generate(
                    backend,
                    _request(input_tokens=input_tokens, max_output_tokens=output_tokens),
                )[-1]["kind"]
                == "completed"
            )
        else:
            with pytest.raises(BackendError) as exc_info:
                list(
                    backend.generate(
                        _request(
                            input_tokens=input_tokens,
                            max_output_tokens=output_tokens,
                        ),
                        threading.Event(),
                    )
                )
            assert exc_info.value.code == "context_length_exceeded"


@pytest.mark.parametrize(
    ("field", "value", "code"),
    [
        ("return_logprobs", True, "unsupported_generation_params"),
        ("rendered_prompt_utf8", b"\xff", "invalid_prompt"),
        ("rendered_prompt_utf8", b"prompt", "unsupported_rendered_prompt"),
        ("input_tokens", True, "invalid_generation_params"),
        ("input_tokens", 0, "invalid_generation_params"),
        ("temperature", float("nan"), "invalid_generation_params"),
        ("top_p", 0.0, "invalid_generation_params"),
        ("temperature", 0.0, "sampling_contract_mismatch"),
        ("top_p", 1.0, "sampling_contract_mismatch"),
        ("stop_sequences", [""], "invalid_generation_params"),
    ],
)
def test_generation_parameters_fail_closed(
    tmp_path: Path, field: str, value: Any, code: str
) -> None:
    with _FakeVLLM(_provider_events(["unused"])) as server:
        backend = _loaded_backend(server, tmp_path)
        request = _request()
        target = request.params if hasattr(request.params, field) else request
        setattr(target, field, value)
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(request, threading.Event()))
    assert exc_info.value.code == code


@pytest.mark.parametrize(
    ("status", "content_type", "events", "code"),
    [
        (503, "text/event-stream", [], "provider_protocol_error"),
        (200, "application/json", [], "provider_protocol_error"),
        (
            200,
            "text/event-stream",
            [{"choices": [{"text": "ok", "finish_reason": "stop"}]}],
            "provider_usage_missing",
        ),
        (
            200,
            "text/event-stream",
            _provider_events(["ok"], input_tokens=4),
            "provider_usage_mismatch",
        ),
    ],
)
def test_provider_protocol_errors_fail_closed(
    tmp_path: Path,
    status: int,
    content_type: str,
    events: list[dict[str, Any]],
    code: str,
) -> None:
    with _FakeVLLM(events) as server:
        server.response_status = status
        server.content_type = content_type
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(_request(), threading.Event()))
    assert exc_info.value.code == code


@pytest.mark.parametrize(
    ("events", "code"),
    [
        ([{"choices": "invalid"}], "provider_protocol_error"),
        ([{"choices": ["invalid"]}], "provider_protocol_error"),
        ([{"choices": [{"text": 1}]}], "provider_protocol_error"),
        ([{"choices": [{"text": "", "finish_reason": "other"}]}], "provider_protocol_error"),
        (
            _provider_events(["ok"]) + [{"choices": [{"text": "late", "finish_reason": None}]}],
            "provider_protocol_error",
        ),
        (
            [
                {"choices": [{"text": "", "finish_reason": "stop"}]},
                {"choices": [{"text": "", "finish_reason": "stop"}]},
            ],
            "provider_protocol_error",
        ),
        ([{"choices": [], "usage": []}], "provider_protocol_error"),
        (
            [
                {"choices": [{"text": "ok", "finish_reason": "length"}]},
                {
                    "choices": [],
                    "usage": {"prompt_tokens": True, "completion_tokens": 2, "total_tokens": 3},
                },
            ],
            "provider_usage_mismatch",
        ),
    ],
)
def test_invalid_provider_events_fail_closed(
    tmp_path: Path, events: list[dict[str, Any]], code: str
) -> None:
    with _FakeVLLM(events) as server:
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(_request(), threading.Event()))
    assert exc_info.value.code == code


@pytest.mark.parametrize(
    ("raw_event", "send_done", "code"),
    [
        (b"not-json", True, "provider_protocol_error"),
        (b"[]", True, "provider_protocol_error"),
        (json.dumps({"choices": []}).encode(), False, "provider_missing_terminal"),
    ],
)
def test_invalid_sse_transport_fails_closed(
    tmp_path: Path, raw_event: bytes, send_done: bool, code: str
) -> None:
    with _FakeVLLM() as server:
        server.raw_events = [raw_event]
        server.send_done = send_done
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(_request(), threading.Event()))
    assert exc_info.value.code == code


def test_reasoning_bytes_count_toward_output_bound(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr("orchard_worker_mlx.vllm_poc._MAX_DECODED_OUTPUT_CHARS", 32)
    with _FakeVLLM(_provider_events(["r" * 33], close_prompt_reasoning=False)) as server:
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            _generate(backend, _request())
    assert exc_info.value.code == "provider_output_too_large"


@pytest.mark.parametrize(
    "malformed",
    [
        "<tool_call>" + " " * 100_000,
        "<tool_call>" * 10_000,
        "<tool_call><function=read>" + " " * 100_000 + "</tool_call>",
        "<tool_call><function=read><parameter=path>" + " " * 100_000 + "</function></tool_call>",
    ],
)
def test_large_malformed_tool_output_fails_closed(tmp_path: Path, malformed: str) -> None:
    tools = [{"type": "function", "function": {"name": "read"}}]
    with _FakeVLLM(_provider_events([malformed])) as server:
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            _generate(backend, _request(tools=tools))
    assert exc_info.value.code == "tool_call_parse_failed"


def test_identity_has_wall_clock_deadline_under_slow_drip(tmp_path: Path) -> None:
    with _FakeVLLM() as server:
        server.identity_drip = True
        backend = VLLMPocBackend(
            config=VLLMPocConfig(endpoint=server.endpoint, identity_timeout_s=0.15)
        )
        started = time.monotonic()
        with pytest.raises(BackendError) as exc_info:
            backend.load_model(model_id=MODEL_ID, version=MODEL_VERSION, model_path=str(tmp_path))
        assert time.monotonic() - started < 0.6
        assert exc_info.value.code == "provider_unavailable"
        assert backend.status()["loaded"] is False


@pytest.mark.parametrize("stall_bytes", [b"", b'data: {"choices":'])
def test_silent_and_midline_cancel_settles_reader_repeatedly(
    tmp_path: Path, stall_bytes: bytes
) -> None:
    baseline = {thread for thread in threading.enumerate() if thread.name == "vllm-poc-reader"}
    with _FakeVLLM() as server:
        server.stall_bytes = stall_bytes
        backend = _loaded_backend(server, tmp_path)
        for _ in range(3):
            server.headers_sent.clear()
            server.client_closed.clear()
            cancel = threading.Event()
            result = []
            backend.start_generation()
            consumer = threading.Thread(
                target=lambda result=result, cancel=cancel: result.extend(
                    backend.generate(_request(), cancel)
                )
            )
            consumer.start()
            assert server.headers_sent.wait(timeout=2)
            cancel.set()
            consumer.join(timeout=0.7)
            assert not consumer.is_alive()
            backend.finish_generation()
            assert result[0]["code"] == "cancelled"
            assert server.client_closed.wait(timeout=1)
            assert backend.health()["ready"]
            assert {
                thread for thread in threading.enumerate() if thread.name == "vllm-poc-reader"
            } == baseline


def test_unsettled_connect_blocks_new_admission_even_after_unload(
    tmp_path: Path, monkeypatch
) -> None:
    import http.client

    entered = threading.Event()
    release = threading.Event()
    original_connect = http.client.HTTPConnection.connect

    def delayed_connect(connection) -> None:
        entered.set()
        release.wait(timeout=4)
        original_connect(connection)

    with _FakeVLLM() as server:
        backend = _loaded_backend(server, tmp_path)
        monkeypatch.setattr(http.client.HTTPConnection, "connect", delayed_connect)
        cancel = threading.Event()
        result = []
        backend.start_generation()
        consumer = threading.Thread(
            target=lambda: result.extend(backend.generate(_request(), cancel))
        )
        try:
            consumer.start()
            assert entered.wait(timeout=1)
            cancel.set()
            consumer.join(timeout=3)
            assert not consumer.is_alive()
            assert result[0]["code"] == "cancelled"
            backend.finish_generation()
            backend.unload_model()
            assert backend.health()["code"] == "provider_reader_unsettled"
            with pytest.raises(BackendError) as exc_info:
                backend.start_generation()
            assert exc_info.value.code == "provider_reader_unsettled"
        finally:
            readers = [
                thread for thread in threading.enumerate() if thread.name == "vllm-poc-reader"
            ]
            release.set()
            for reader in readers:
                reader.join(timeout=1)


def test_cancellation_closes_provider_stream(tmp_path: Path) -> None:
    with _FakeVLLM() as server:
        server.stall = True
        backend = _loaded_backend(server, tmp_path)
        cancel = threading.Event()
        result: list[dict[str, Any]] = []

        def consume() -> None:
            result.extend(backend.generate(_request(), cancel))

        consumer = threading.Thread(target=consume)
        consumer.start()
        assert server.request_seen.wait(timeout=2)
        cancel.set()
        consumer.join(timeout=3)
        assert not consumer.is_alive()
        assert result == [
            {
                "kind": "failed",
                "code": "cancelled",
                "message": "request cancelled",
                "retryable": False,
            }
        ]
        assert server.client_closed.wait(timeout=2)


def test_single_flight_and_logical_unload(tmp_path: Path) -> None:
    with _FakeVLLM() as server:
        backend = _loaded_backend(server, tmp_path)
        backend.start_generation()
        with pytest.raises(BackendError, match="active generation"):
            backend.start_generation()
        with pytest.raises(BackendError, match="active generation"):
            backend.unload_model()
        backend.finish_generation()
        backend.unload_model()
    assert backend.status()["loaded"] is False


def test_fake_provider_crosses_worker_runtime_protocol(tmp_path: Path) -> None:
    with _FakeVLLM(_provider_events(["protocol ok"])) as server:
        backend = _loaded_backend(server, tmp_path)
        servicer = WorkerRuntimeServicer(backend)
        status = servicer.GetStatus(worker_runtime_pb2.WorkerStatusRequest(), None)
        context = SimpleNamespace(add_callback=lambda _callback: True)
        events = list(
            servicer.Generate(
                runtime_pb2.ExecuteInferenceRequest(
                    request_id="kap112-fake-integration",
                    model_id=MODEL_ID,
                    version=MODEL_VERSION,
                    rendered_prompt_utf8=b"prompt<think>\n",
                    input_tokens=3,
                    params=common_pb2.GenerationParams(
                        max_output_tokens=8,
                        temperature=1.0,
                        top_p=0.95,
                    ),
                ),
                context,
            )
        )

    assert status.supports_prompt_token_ids is False
    assert [event.WhichOneof("event") for event in events] == [
        "output_text_delta",
        "completed",
    ], events
    assert events[0].output_text_delta.delta == "brief reasoning</think>protocol ok"
    assert events[1].completed.usage.total_tokens == 5


def test_parser_rejects_truncated_partial_control_marker() -> None:
    parser = _QwenPocOutputParser(_params())
    parser.push("<thi")
    with pytest.raises(BackendError) as exc_info:
        parser.finish("length")
    assert exc_info.value.code == "reasoning_parser_conformance_failed"


@pytest.mark.parametrize("finish_reason", ["stop", "length"])
@pytest.mark.parametrize(
    "marker",
    ["<tool_call>", "</tool_call>", "<function=", "</function>", "<parameter=", "</parameter>"],
)
def test_parser_rejects_every_truncated_tool_control_marker_prefix(
    finish_reason: str, marker: str
) -> None:
    for length in range(1, len(marker)):
        parser = _QwenPocOutputParser(_params())
        parser.push(f"reasoning</think>answer{marker[:length]}")
        with pytest.raises(BackendError) as exc_info:
            parser.finish(finish_reason)
        assert exc_info.value.code in {
            "tool_call_parse_failed",
            "reasoning_parser_conformance_failed",
        }

    parser = _QwenPocOutputParser(_params())
    parser.push(f"reasoning</think>answer{marker}")
    with pytest.raises(BackendError) as exc_info:
        parser.finish(finish_reason)
    assert exc_info.value.code == "tool_call_parse_failed"


@pytest.mark.parametrize("completion_tokens", [9, MAX_TOTAL_TOKENS])
def test_usage_cannot_exceed_request_or_total_envelope(
    tmp_path: Path, completion_tokens: int
) -> None:
    events = [
        {"choices": [{"text": "unused", "finish_reason": "stop"}]},
        {
            "choices": [],
            "usage": {
                "prompt_tokens": 3,
                "completion_tokens": completion_tokens,
                "total_tokens": 3 + completion_tokens,
            },
        },
    ]
    with _FakeVLLM(events) as server:
        backend = _loaded_backend(server, tmp_path)
        with pytest.raises(BackendError) as exc_info:
            list(backend.generate(_request(max_output_tokens=8), threading.Event()))
    assert exc_info.value.code == "provider_usage_mismatch"


@pytest.mark.parametrize(
    ("tools_json", "tool_choice_json"),
    [
        (b"{}", b'"auto"'),
        (b"not-json", b'"auto"'),
        (
            json.dumps([{"function": {"name": "read"}}, {"function": {"name": "read"}}]).encode(),
            b'"auto"',
        ),
        (b"[]", b'"required"'),
        (
            json.dumps([{"function": {"name": "read"}}]).encode(),
            json.dumps({"function": {"name": "write"}}).encode(),
        ),
    ],
)
def test_parser_rejects_invalid_tool_configuration(
    tools_json: bytes, tool_choice_json: bytes
) -> None:
    params = _params()
    params.tools_json = tools_json
    params.tool_choice_json = tool_choice_json
    with pytest.raises(BackendError) as exc_info:
        _QwenPocOutputParser(params)
    assert exc_info.value.code == "invalid_generation_params"


@pytest.mark.parametrize(
    "text",
    [
        *[
            "narration" + marker[:length] + "<tool_call><function=read></function></tool_call>"
            for marker in (
                "<tool_call>",
                "</tool_call>",
                "<function=",
                "</function>",
                "<parameter=",
                "</parameter>",
            )
            for length in range(1, 4)
        ],
        "narration</tool_call><tool_call><function=read></function></tool_call>",
        "narration<tool_cal<tool_call><function=read></function></tool_call>",
        "narration<function=read<tool_call><function=read></function></tool_call>",
        "<tool_call><function=read></function></tool_call>trailing text",
        (
            "<tool_call><function=read></function></tool_call>between calls"
            "<tool_call><function=read></function></tool_call>"
        ),
        "<tool_call><function=read><parameter=x>1</parameter><parameter=x>2</parameter></function></tool_call>",
        "<tool_call><function=read>garbage</function></tool_call>",
    ],
)
def test_parser_rejects_ambiguous_tool_output(text: str) -> None:
    parser = _QwenPocOutputParser(
        _params(tools=[{"type": "function", "function": {"name": "read"}}])
    )
    for char in "reasoning</think>" + text:
        parser.push(char)
    with pytest.raises(BackendError) as exc_info:
        parser.finish("stop")
    assert exc_info.value.code == "tool_call_parse_failed"


def _consume(iterator: Iterator[dict[str, Any]]) -> list[dict[str, Any]]:
    return list(iterator)
