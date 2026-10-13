from __future__ import annotations

import http.client
import json
import logging
import math
import queue
import re
import socket
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from uuid import uuid4

from orchard_worker_mlx.backends import (
    BackendError,
    BackendHealth,
    BackendPrefixCacheScore,
    BackendPrefixCacheStatus,
    BackendStatus,
    cancelled_event,
)
from orchard_worker_mlx.reasoning import (
    PARSER_VERSION_V1,
    PROMPT_OPENED_FAMILY,
    StatefulReasoningParser,
)

logger = logging.getLogger(__name__)

MODEL_ID = "Qwen/Qwen3.8-27B"
MODEL_VERSION = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
SERVED_MODEL_ID = "orchard-qwen3.8-27b-poc"
DEFAULT_ENDPOINT = "http://127.0.0.1:58080/v1/completions"
MAX_INPUT_TOKENS = 131_072
MAX_OUTPUT_TOKENS = 8_192
MAX_TOTAL_TOKENS = 139_264
PARSER_ID = "qwen3.8-poc-raw-v1"
RENDER_CONTRACT = "vllm-poc-legacy-framing"
RENDER_CONTRACT_VERSION = "1"
SAMPLING_CONTROLS = {
    "temperature": 1.0,
    "top_p": 0.95,
    "top_k": 20,
    "min_p": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,
}

_MAX_HTTP_BODY_BYTES = 1_048_576
_MAX_SSE_LINE_BYTES = 1_048_576
_MAX_DECODED_OUTPUT_CHARS = 4_194_304
_TOOL_START = "<tool_call>"
_TOOL_END = "</tool_call>"
_TOOL_CONTROL_MARKERS = (
    _TOOL_START,
    _TOOL_END,
    "<function=",
    "</function>",
    "<parameter=",
    "</parameter>",
)
_NAME_RE = re.compile(r"[A-Za-z0-9_.:-]+")


@dataclass(frozen=True, slots=True)
class VLLMPocConfig:
    endpoint: str = DEFAULT_ENDPOINT
    request_timeout_s: float = 600.0
    identity_timeout_s: float = 5.0

    def __post_init__(self) -> None:
        parsed = urlsplit(self.endpoint)
        if (
            parsed.scheme != "http"
            or parsed.hostname != "127.0.0.1"
            or parsed.port is None
            or parsed.path != "/v1/completions"
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("vllm_poc endpoint must be loopback HTTP /v1/completions")
        if self.request_timeout_s <= 0 or self.identity_timeout_s <= 0:
            raise ValueError("vllm_poc timeouts must be positive")


class VLLMPocBackend:
    """Disposable exact-tuple vLLM adapter for the KAP-112 source POC."""

    def __init__(self, *, config: VLLMPocConfig | None = None) -> None:
        self._config = config or VLLMPocConfig()
        self._loaded_model: tuple[str, str, str] | None = None
        self._active_request_count = 0
        self._lock = threading.Lock()
        self._reader_unsettled = False

    def status(self) -> BackendStatus:
        with self._lock:
            return BackendStatus(
                loaded=self._loaded_model is not None,
                active_request_count=self._active_request_count,
                max_concurrency=1,
                supports_prompt_token_ids=False,
            )

    def health(self) -> BackendHealth:
        with self._lock:
            if self._reader_unsettled:
                return BackendHealth(
                    ready=False,
                    code="provider_reader_unsettled",
                    message="provider reader did not settle; replace the Worker",
                )
        return BackendHealth(ready=True, code="", message="")

    def prefix_cache_status(self) -> BackendPrefixCacheStatus:
        return BackendPrefixCacheStatus(
            implementation="none",
            enabled=False,
            entry_count=0,
            total_bytes=0,
            hits=0,
            misses=0,
            failures=0,
            stores=0,
            evictions=0,
            configured_max_entries=0,
            configured_max_bytes=0,
            status_code="unavailable",
            status_message="prefix cache status unavailable for vllm_poc",
            session_started_unix_ms=0,
            prefix_cache_fingerprints=[],
        )

    def load_model(self, *, model_id: str, version: str, model_path: str) -> None:
        if model_id != MODEL_ID or version != MODEL_VERSION:
            raise BackendError(
                "poc_tuple_mismatch",
                "model identity does not match the accepted KAP-112 tuple",
                False,
            )
        path = Path(model_path)
        if not path.is_dir():
            raise BackendError("model_path_missing", "model path is missing", False)

        self._verify_provider_identity()
        with self._lock:
            if self._active_request_count:
                raise BackendError("worker_busy", "worker has an active generation", False)
            self._loaded_model = (model_id, version, str(path.resolve()))

    def unload_model(self) -> None:
        with self._lock:
            if self._active_request_count:
                raise BackendError("worker_busy", "worker has an active generation", False)
            self._loaded_model = None

    def start_generation(self) -> None:
        with self._lock:
            if self._reader_unsettled:
                raise BackendError(
                    "provider_reader_unsettled", "provider reader did not settle", False
                )
            if self._loaded_model is None:
                raise BackendError("model_not_loaded", "model is not loaded", False)
            if self._active_request_count:
                raise BackendError("worker_busy", "worker already has an active generation", False)
            self._active_request_count = 1

    def finish_generation(self) -> None:
        with self._lock:
            self._active_request_count = max(0, self._active_request_count - 1)

    def record_fingerprint(self, fingerprint: str) -> None:
        del fingerprint

    def get_fingerprints(self) -> list[str]:
        return []

    def score_prefix_cache(
        self,
        *,
        model_ref: Any,
        fingerprint: str,
        request_id: str,
        deadline_unix_ms: int,
    ) -> BackendPrefixCacheScore:
        del model_ref, fingerprint, request_id, deadline_unix_ms
        return BackendPrefixCacheScore(
            status_code="unavailable",
            status_message="prefix cache score unavailable for vllm_poc",
            resident_fingerprint_match=False,
            score_tier="unknown",
            session_started_unix_ms=0,
        )

    def generate(self, request: Any, cancel_event: threading.Event) -> Iterator[dict[str, Any]]:
        self._validate_request_binding(request)
        payload = self._request_payload(request)
        output_parser = _QwenPocOutputParser(getattr(request, "params", None))
        usage: dict[str, int] | None = None
        provider_finish: str | None = None

        try:
            for item in self._stream_provider(payload, cancel_event):
                if cancel_event.is_set():
                    yield cancelled_event()
                    return

                parsed_usage = _normalize_usage(item.get("usage"), request)
                if parsed_usage is not None:
                    usage = parsed_usage

                choices = item.get("choices")
                if not isinstance(choices, list):
                    raise BackendError(
                        "provider_protocol_error", "provider choices were invalid", False
                    )
                if not choices:
                    continue
                if len(choices) != 1 or not isinstance(choices[0], dict):
                    raise BackendError(
                        "provider_protocol_error", "provider returned an invalid choice", False
                    )
                if provider_finish is not None:
                    raise BackendError(
                        "provider_protocol_error",
                        "provider returned a choice after terminal",
                        False,
                    )

                choice = choices[0]
                text = choice.get("text", "")
                if not isinstance(text, str):
                    raise BackendError(
                        "provider_protocol_error", "provider text delta was invalid", False
                    )
                output_parser.push(text)

                finish_reason = choice.get("finish_reason")
                if finish_reason is not None:
                    if finish_reason not in {"stop", "length"}:
                        raise BackendError(
                            "provider_protocol_error",
                            "provider finish reason was unsupported",
                            False,
                        )
                    provider_finish = finish_reason
        except BackendError as exc:
            if exc.code == "cancelled" or cancel_event.is_set():
                yield cancelled_event()
                return
            raise

        if cancel_event.is_set():
            yield cancelled_event()
            return
        if provider_finish is None:
            raise BackendError(
                "provider_missing_terminal", "provider ended without a terminal choice", False
            )
        if usage is None:
            raise BackendError(
                "provider_usage_missing", "provider did not return token usage", False
            )

        events, tool_calls = output_parser.finish(provider_finish)
        yield from events
        yield {
            "kind": "completed",
            "finish_reason": (
                "FINISH_REASON_TOOL_CALLS"
                if tool_calls
                else (
                    "FINISH_REASON_LENGTH" if provider_finish == "length" else "FINISH_REASON_STOP"
                )
            ),
            "usage": usage,
        }

    def _verify_provider_identity(self) -> None:
        parsed = urlsplit(self._config.endpoint)
        connection = http.client.HTTPConnection(
            parsed.hostname,
            parsed.port,
            timeout=self._config.identity_timeout_s,
        )
        deadline = time.monotonic() + self._config.identity_timeout_s
        timer = None
        response = None
        try:
            connection.connect()
            connection.auto_open = 0
            timer = threading.Timer(
                max(0.0, deadline - time.monotonic()),
                _shutdown_socket,
                args=(connection.sock,),
            )
            timer.start()
            connection.request("GET", "/v1/models", headers={"Accept": "application/json"})
            response = connection.getresponse()
            body = response.read(_MAX_HTTP_BODY_BYTES + 1)
            if time.monotonic() >= deadline:
                raise TimeoutError("provider identity deadline exceeded")
        except (OSError, http.client.HTTPException) as exc:
            raise BackendError(
                "provider_unavailable", "vllm_poc provider identity is unavailable", True
            ) from exc
        finally:
            if timer is not None:
                timer.cancel()
                timer.join()
            if response is not None:
                response.close()
            connection.close()

        if response.status != 200 or len(body) > _MAX_HTTP_BODY_BYTES:
            raise BackendError(
                "provider_identity_mismatch", "vllm_poc provider identity did not match", False
            )
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise BackendError(
                "provider_identity_mismatch", "vllm_poc provider identity did not match", False
            ) from None

        data = payload.get("data") if isinstance(payload, dict) else None
        ids = {
            item.get("id")
            for item in data or []
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        if ids != {SERVED_MODEL_ID}:
            raise BackendError(
                "provider_identity_mismatch", "vllm_poc provider identity did not match", False
            )

    def _validate_request_binding(self, request: Any) -> None:
        with self._lock:
            loaded_model = self._loaded_model
        if loaded_model is None:
            raise BackendError("model_not_loaded", "model is not loaded", False)
        if (
            getattr(request, "model_id", "") != loaded_model[0]
            or getattr(request, "version", "") != loaded_model[1]
        ):
            raise BackendError("model_not_loaded", "model is not loaded on this worker", False)

    def _request_payload(self, request: Any) -> dict[str, Any]:
        if (
            getattr(request, "prompt_token_ids", [])
            or getattr(request, "return_token_ids", False) is True
            or getattr(request, "return_logprobs", False) is True
        ):
            raise BackendError(
                "unsupported_generation_params",
                "vllm_poc accepts rendered prompts and text output only",
                False,
            )
        prompt_bytes = getattr(request, "rendered_prompt_utf8", b"")
        if not isinstance(prompt_bytes, bytes):
            prompt_bytes = bytes(prompt_bytes)
        try:
            prompt = prompt_bytes.decode("utf-8")
        except UnicodeDecodeError:
            raise BackendError("invalid_prompt", "rendered prompt is not UTF-8", False) from None
        if not prompt.endswith("<think>\n"):
            raise BackendError(
                "unsupported_rendered_prompt",
                "vllm_poc requires the snapshot's prompt-opened legacy framing",
                False,
            )

        input_tokens = getattr(request, "input_tokens", 0)
        params = getattr(request, "params", None)
        output_tokens = getattr(params, "max_output_tokens", 0) if params is not None else 0
        if isinstance(input_tokens, bool) or not isinstance(input_tokens, int) or input_tokens < 1:
            raise BackendError("invalid_generation_params", "input token count is invalid", False)
        if (
            isinstance(output_tokens, bool)
            or not isinstance(output_tokens, int)
            or output_tokens < 1
        ):
            raise BackendError("invalid_generation_params", "output token limit is invalid", False)
        if (
            input_tokens > MAX_INPUT_TOKENS
            or output_tokens > MAX_OUTPUT_TOKENS
            or input_tokens + output_tokens > MAX_TOTAL_TOKENS
        ):
            raise BackendError(
                "context_length_exceeded",
                "request exceeds the accepted KAP-112 context envelope",
                False,
            )

        try:
            temperature = float(getattr(params, "temperature", 0.0))
            top_p = float(getattr(params, "top_p", 1.0))
        except (TypeError, ValueError):
            raise BackendError(
                "invalid_generation_params", "sampling parameters are invalid", False
            ) from None
        raw_stop_sequences = getattr(params, "stop_sequences", [])
        try:
            stop_sequences = (
                []
                if raw_stop_sequences is None
                else list(raw_stop_sequences)
                if not isinstance(raw_stop_sequences, (str, bytes))
                else None
            )
        except TypeError:
            stop_sequences = None
        if (
            not math.isfinite(temperature)
            or not math.isfinite(top_p)
            or temperature < 0
            or top_p <= 0
            or top_p > 1
        ):
            raise BackendError(
                "invalid_generation_params", "sampling parameters are invalid", False
            )
        if temperature != SAMPLING_CONTROLS["temperature"] or top_p != SAMPLING_CONTROLS["top_p"]:
            raise BackendError(
                "sampling_contract_mismatch",
                "request sampling does not match the accepted KAP-112 medium-thinking sampler",
                False,
            )
        if stop_sequences is None or not all(
            isinstance(item, str) and item for item in stop_sequences
        ):
            raise BackendError("invalid_generation_params", "stop sequences are invalid", False)

        return {
            "model": SERVED_MODEL_ID,
            "prompt": prompt,
            "max_tokens": output_tokens,
            **SAMPLING_CONTROLS,
            "stop": stop_sequences or None,
            "stream": True,
            "stream_options": {"include_usage": True},
        }

    def _stream_provider(
        self, payload: dict[str, Any], cancel_event: threading.Event
    ) -> Iterator[dict[str, Any]]:
        parsed = urlsplit(self._config.endpoint)
        items: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=64)
        stop_reader = threading.Event()
        transport_lock = threading.Lock()
        transport_socket: socket.socket | None = None
        connection = http.client.HTTPConnection(
            parsed.hostname,
            parsed.port,
            timeout=self._config.request_timeout_s,
        )

        def enqueue(kind: str, value: Any) -> bool:
            while not stop_reader.is_set():
                try:
                    items.put((kind, value), timeout=0.1)
                    return True
                except queue.Full:
                    continue
            return False

        def read_stream() -> None:
            nonlocal transport_socket
            response = None
            try:
                connection.connect()
                connection.auto_open = 0
                with transport_lock:
                    transport_socket = connection.sock
                    if stop_reader.is_set():
                        _shutdown_socket(transport_socket)
                        return
                body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
                connection.request(
                    "POST",
                    parsed.path,
                    body=body,
                    headers={
                        "Accept": "text/event-stream",
                        "Content-Type": "application/json",
                    },
                )
                response = connection.getresponse()
                if response.status != 200:
                    response.read(_MAX_HTTP_BODY_BYTES + 1)
                    enqueue("error", "provider rejected the request")
                    return
                if response.getheader("Content-Type", "").split(";", 1)[0].strip() != (
                    "text/event-stream"
                ):
                    enqueue("error", "provider response was not an event stream")
                    return

                while not stop_reader.is_set():
                    line = response.readline(_MAX_SSE_LINE_BYTES + 1)
                    if not line:
                        enqueue("eof", None)
                        return
                    if len(line) > _MAX_SSE_LINE_BYTES:
                        enqueue("error", "provider event exceeded the size limit")
                        return
                    stripped = line.strip()
                    if not stripped or stripped.startswith(b":"):
                        continue
                    if not stripped.startswith(b"data:"):
                        continue
                    data = stripped[5:].strip()
                    if data == b"[DONE]":
                        enqueue("done", None)
                        return
                    try:
                        event = json.loads(data)
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        enqueue("error", "provider event was invalid JSON")
                        return
                    if not isinstance(event, dict):
                        enqueue("error", "provider event was invalid")
                        return
                    if not enqueue("event", event):
                        return
            except (OSError, http.client.HTTPException, ValueError):
                enqueue("error", "provider stream failed")
            finally:
                if response is not None:
                    response.close()
                connection.close()

        reader = threading.Thread(target=read_stream, name="vllm-poc-reader", daemon=True)
        reader.start()
        deadline = time.monotonic() + self._config.request_timeout_s
        try:
            while True:
                if cancel_event.is_set():
                    raise BackendError("cancelled", "request cancelled", False)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise BackendError("provider_timeout", "provider request timed out", True)
                try:
                    kind, value = items.get(timeout=min(0.1, remaining))
                except queue.Empty:
                    continue
                if kind == "event":
                    yield value
                elif kind == "done":
                    return
                elif kind == "eof":
                    raise BackendError(
                        "provider_missing_terminal", "provider stream ended before [DONE]", False
                    )
                else:
                    raise BackendError("provider_protocol_error", str(value), False)
        finally:
            stop_reader.set()
            with transport_lock:
                _shutdown_socket(transport_socket)
            reader.join(timeout=2.0)
            if reader.is_alive():
                with self._lock:
                    self._reader_unsettled = True
                logger.error("vllm_poc provider reader did not stop after connection close")


class _QwenPocOutputParser:
    def __init__(self, params: Any) -> None:
        self._reasoning = StatefulReasoningParser(
            parser_family=PROMPT_OPENED_FAMILY,
            parser_version=PARSER_VERSION_V1,
            generation_policy="enabled",
            render_contract=RENDER_CONTRACT,
            render_contract_version=RENDER_CONTRACT_VERSION,
            synthetic_prompt_opened_render_contracts=((RENDER_CONTRACT, RENDER_CONTRACT_VERSION),),
        )
        self._parts: list[str] = []
        self._raw_parts: list[str] = []
        self._char_count = 0
        self._tools = _decode_json_bytes(getattr(params, "tools_json", b""), "tools_json", [])
        self._tool_choice = _decode_json_bytes(
            getattr(params, "tool_choice_json", b""), "tool_choice_json", "auto"
        )
        if not isinstance(self._tools, list):
            raise BackendError(
                "invalid_generation_params", "tools_json must decode to an array", False
            )
        tool_names = _requested_tool_names(self._tools)
        requires_tool, named_tool, _tools_disabled = _tool_choice_policy(self._tool_choice)
        if requires_tool and not tool_names:
            raise BackendError(
                "invalid_generation_params",
                "tool choice requires at least one tool definition",
                False,
            )
        if named_tool is not None and named_tool not in tool_names:
            raise BackendError(
                "invalid_generation_params",
                "named tool choice must identify a requested tool",
                False,
            )

    def push(self, text: str) -> None:
        self._char_count += len(text)
        if self._char_count > _MAX_DECODED_OUTPUT_CHARS:
            raise BackendError(
                "provider_output_too_large", "provider output exceeded the size limit", False
            )
        self._raw_parts.append(text)
        delta = self._reasoning.push(text)
        self._append(delta.final_text)

    def finish(self, finish_reason: str) -> tuple[list[dict[str, Any]], bool]:
        terminal = self._reasoning.finish("length" if finish_reason == "length" else "stop")
        if not terminal.ok:
            raise BackendError(
                terminal.failure_code or "reasoning_parser_conformance_failed",
                terminal.failure_reason or "reasoning parser conformance failed",
                False,
            )
        self._append(terminal.final_text)
        text = "".join(self._parts)
        events, tool_calls = _parse_final_output(text, self._tools, self._tool_choice)
        raw = "".join(self._raw_parts)
        # KAP-49 retains legacy-blended bytes; framing only separates tool syntax.
        prefix = raw[: -len(text)] if text else raw
        if prefix:
            if events and events[0]["kind"] == "output_text_delta":
                events[0]["delta"] = prefix + events[0]["delta"]
            else:
                events.insert(0, {"kind": "output_text_delta", "delta": prefix})
        return events, tool_calls

    def _append(self, text: str) -> None:
        if text:
            self._parts.append(text)


def _parse_final_output(
    text: str, tools: list[Any], tool_choice: Any
) -> tuple[list[dict[str, Any]], bool]:
    requires_tool, named_tool, tools_disabled = _tool_choice_policy(tool_choice)
    blocks: list[tuple[int, int, str]] = []
    cursor = 0
    while (start := text.find(_TOOL_START, cursor)) != -1:
        body_start = start + len(_TOOL_START)
        end = text.find(_TOOL_END, body_start)
        if end == -1 or _TOOL_START in text[body_start:end]:
            raise BackendError(
                "tool_call_parse_failed",
                "provider returned an incomplete or nested tool call",
                False,
            )
        cursor = end + len(_TOOL_END)
        blocks.append((start, cursor, text[body_start:end]))
    has_marker = any(marker in text for marker in _TOOL_CONTROL_MARKERS)

    if not blocks:
        if has_marker or _has_partial_tool_marker(text):
            raise BackendError(
                "tool_call_parse_failed", "provider returned an incomplete tool call", False
            )
        if requires_tool:
            raise BackendError(
                "tool_choice_not_satisfied", "model did not emit a required tool call", False
            )
        if not text.strip():
            raise BackendError(
                "provider_empty_output", "provider returned no final answer text", False
            )
        return ([{"kind": "output_text_delta", "delta": text}]), False

    if tools_disabled or not tools:
        raise BackendError(
            "tool_call_parse_failed", "provider emitted an unrequested tool call", False
        )
    public_prefix = text[: blocks[0][0]]
    if (
        (_has_partial_tool_marker(public_prefix) or _has_tool_control_syntax(public_prefix))
        or any(
            text[blocks[index - 1][1] : blocks[index][0]].strip() for index in range(1, len(blocks))
        )
        or text[blocks[-1][1] :].strip()
    ):
        raise BackendError("tool_call_parse_failed", "provider mixed text with tool calls", False)

    requested_names = _requested_tool_names(tools)
    events: list[dict[str, Any]] = (
        [{"kind": "output_text_delta", "delta": public_prefix}] if public_prefix else []
    )
    for index, block in enumerate(blocks):
        name, arguments = _parse_tool_block(block[2])
        if name not in requested_names:
            raise BackendError(
                "tool_call_parse_failed", "provider emitted an unrequested function", False
            )
        if named_tool is not None and name != named_tool:
            raise BackendError(
                "tool_choice_not_satisfied", "model did not emit the required function", False
            )
        events.append(
            {
                "kind": "tool_call_delta",
                "tool_call_id": f"call_{uuid4().hex}",
                "delta": {
                    "index": index,
                    "type": "function",
                    "function": {
                        "name": name,
                        "arguments_delta": json.dumps(
                            arguments,
                            ensure_ascii=False,
                            allow_nan=False,
                            separators=(",", ":"),
                        ),
                    },
                },
            }
        )
    return events, True


def _has_partial_tool_marker(text: str) -> bool:
    for marker in _TOOL_CONTROL_MARKERS:
        for length in range(1, len(marker)):
            if text.endswith(marker[:length]):
                return True
    return False


def _has_tool_control_syntax(text: str) -> bool:
    return any(marker in text for marker in _TOOL_CONTROL_MARKERS) or any(
        marker[:length] in text
        for marker in _TOOL_CONTROL_MARKERS
        for length in range(4, len(marker))
    )


def _parse_tool_block(body: str) -> tuple[str, dict[str, Any]]:
    body = body.strip()
    name_end = body.find(">")
    if not body.startswith("<function=") or not body.endswith("</function>") or name_end == -1:
        raise BackendError(
            "tool_call_parse_failed", "provider returned an invalid tool call", False
        )
    name = body[len("<function=") : name_end]
    if _NAME_RE.fullmatch(name) is None:
        raise BackendError("tool_call_parse_failed", "provider returned an invalid function", False)
    parameter_body = body[name_end + 1 : -len("</function>")]
    arguments: dict[str, Any] = {}
    cursor = 0
    while cursor < len(parameter_body):
        if parameter_body[cursor].isspace():
            cursor += 1
            continue
        name_end = parameter_body.find(">", cursor)
        value_end = parameter_body.find("</parameter>", name_end + 1)
        if (
            not parameter_body.startswith("<parameter=", cursor)
            or name_end == -1
            or value_end == -1
        ):
            raise BackendError(
                "tool_call_parse_failed", "provider returned invalid tool arguments", False
            )
        key = parameter_body[cursor + len("<parameter=") : name_end]
        raw_value = parameter_body[name_end + 1 : value_end]
        if _NAME_RE.fullmatch(key) is None or any(
            marker in raw_value for marker in _TOOL_CONTROL_MARKERS
        ):
            raise BackendError(
                "tool_call_parse_failed", "provider returned ambiguous tool arguments", False
            )
        if key in arguments:
            raise BackendError(
                "tool_call_parse_failed", "provider returned duplicate tool arguments", False
            )
        arguments[key] = _parse_parameter_value(raw_value)
        cursor = value_end + len("</parameter>")
    return name, arguments


def _parse_parameter_value(value: str) -> Any:
    stripped = value.strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return stripped


def _requested_tool_names(tools: list[Any]) -> set[str]:
    names: set[str] = set()
    for tool in tools:
        function = tool.get("function") if isinstance(tool, dict) else None
        name = function.get("name") if isinstance(function, dict) else None
        if not isinstance(name, str) or not name:
            raise BackendError("invalid_generation_params", "tool definition is invalid", False)
        if name in names:
            raise BackendError("invalid_generation_params", "tool names must be unique", False)
        names.add(name)
    return names


def _tool_choice_policy(tool_choice: Any) -> tuple[bool, str | None, bool]:
    if tool_choice in (None, "auto"):
        return False, None, False
    if tool_choice == "none":
        return False, None, True
    if tool_choice == "required":
        return True, None, False
    if isinstance(tool_choice, dict):
        function = tool_choice.get("function")
        name = function.get("name") if isinstance(function, dict) else None
        if isinstance(name, str) and name:
            return True, name, False
    raise BackendError("invalid_generation_params", "tool_choice_json is invalid", False)


def _decode_json_bytes(payload: Any, field: str, default: Any) -> Any:
    if payload in (None, b"", ""):
        return default
    try:
        text = payload.decode("utf-8") if isinstance(payload, bytes) else payload
        return json.loads(text)
    except (AttributeError, UnicodeDecodeError, json.JSONDecodeError, TypeError):
        raise BackendError("invalid_generation_params", f"{field} is invalid JSON", False) from None


def _normalize_usage(raw_usage: Any, request: Any) -> dict[str, int] | None:
    if raw_usage is None:
        return None
    if not isinstance(raw_usage, dict):
        raise BackendError("provider_protocol_error", "provider usage was invalid", False)
    prompt_tokens = raw_usage.get("prompt_tokens")
    completion_tokens = raw_usage.get("completion_tokens")
    total_tokens = raw_usage.get("total_tokens")
    expected_prompt_tokens = getattr(request, "input_tokens", 0)
    params = getattr(request, "params", None)
    requested_output_tokens = getattr(params, "max_output_tokens", 0)
    if (
        isinstance(prompt_tokens, bool)
        or not isinstance(prompt_tokens, int)
        or isinstance(completion_tokens, bool)
        or not isinstance(completion_tokens, int)
        or isinstance(total_tokens, bool)
        or not isinstance(total_tokens, int)
        or prompt_tokens < 0
        or completion_tokens < 0
        or total_tokens != prompt_tokens + completion_tokens
        or prompt_tokens != expected_prompt_tokens
        or completion_tokens > requested_output_tokens
        or total_tokens > MAX_TOTAL_TOKENS
    ):
        raise BackendError("provider_usage_mismatch", "provider usage did not match", False)
    return {
        "input_tokens": prompt_tokens,
        "output_tokens": completion_tokens,
        "total_tokens": total_tokens,
    }


def _shutdown_socket(sock: socket.socket | None) -> None:
    if sock is not None:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
