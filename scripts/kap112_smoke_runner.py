#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import hashlib
import http.client
import http.server
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from pathlib import Path
from typing import Any

MODEL = "Qwen/Qwen3.8-27B@1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
REQUIRED_PORTS = {4000: "Orchard HTTP", 50071: "Runtime Endpoint"}
PROVIDER_PORT = 58080
POSTGRES_PORT = 55432
OPENCODE_REQUEST_MAX_BYTES = 16 * 1024 * 1024
MAX_OUTPUT_TOKENS = 8192
STAGE_RECEIPT_FILENAME = "kap112-stage-receipts.json"
STAGE_COMPLETION_FIELDS = {
    "database_setup": {"reasoning_contract_sha256"},
    "orchard_runtime": {"logical_load_confirmed", "model"},
    "direct_api": {
        "elapsed_ms",
        "model",
        "request_id_sha256",
        "usage",
        "console_rendered",
        "scheduler_selected",
    },
    "short_opencode": {
        "event_count",
        "model_turn_count",
        "tool_event_count",
        "completed_tool_event_count",
        "reasoning_event_count",
        "finish_reason",
        "finish_tokens",
        "terminal_text_sha256",
        "elapsed_ms",
        "api_requests",
        "fixture_outcome",
        "short_diff_sha256",
    },
    "long_context": {
        "event_count",
        "model_turn_count",
        "tool_event_count",
        "reasoning_event_count",
        "finish_reason",
        "finish_tokens",
        "observed_input_tokens",
        "elapsed_ms",
        "api_requests",
        "terminal_answer_sha256",
    },
    "overflow": {
        "elapsed_ms",
        "input_tokens",
        "error_code",
        "http_status",
        "api_requests",
        "durable_request_delta",
    },
    "logical_unload": {"ack", "still_loaded"},
    "protocol_aggregate": {
        "tool_schema_translation_count",
        "tool_history_translation_count",
        "tool_result_identity_count",
        "tool_stream_expansion_count",
    },
    "proof": {"result_sha256"},
}
STAGE_OBSERVATION_FIELDS = {
    "short_opencode": {"api_attempts", "api_requests", "model_turn_count"},
    "long_context": {"api_attempts", "api_requests", "model_turn_count"},
    "overflow": {"api_attempts", "api_requests", "model_turn_count"},
}
STAGE_BOOLEAN_FIELDS = {
    "ack",
    "console_rendered",
    "logical_load_confirmed",
    "scheduler_selected",
    "still_loaded",
}
STAGE_COUNT_FIELDS = {
    "api_requests",
    "completed_tool_event_count",
    "durable_request_delta",
    "elapsed_ms",
    "event_count",
    "http_status",
    "input_tokens",
    "model_turn_count",
    "reasoning_event_count",
    "tool_event_count",
    "tool_history_translation_count",
    "tool_result_identity_count",
    "tool_schema_translation_count",
    "tool_stream_expansion_count",
}
STAGE_HASH_FIELDS = {
    "error_sha256",
    "reasoning_contract_sha256",
    "request_id_sha256",
    "result_sha256",
    "short_diff_sha256",
    "terminal_answer_sha256",
    "terminal_text_sha256",
}
TOKENIZER_ASSETS = ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja")
LINUX_UNIX_SOCKET_PATH_MAX_BYTES = 107
WORKER_SOCKET_FILENAME_PROBE = "orchard-worker-" + ("0" * 16) + ".sock"
PASSTHROUGH_ENVIRONMENT = {
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "TERM",
    "TMPDIR",
    "USER",
}
PASSTHROUGH_PREFIXES = ("MISE_", "PG")


class ProofFailure(RuntimeError):
    pass


class ResponseSequenceDrift(ProofFailure):
    def __init__(self, evidence: dict[str, Any]) -> None:
        super().__init__(
            "OpenCode response stream event sequence drifted: "
            + json.dumps(evidence, sort_keys=True)
        )
        self.evidence = evidence


def bounded_environment(source: dict[str, str]) -> dict[str, str]:
    return {
        key: value
        for key, value in source.items()
        if key in PASSTHROUGH_ENVIRONMENT
        or any(key.startswith(prefix) for prefix in PASSTHROUGH_PREFIXES)
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bundle_tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    paths: list[Path] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ProofFailure("proof bundle contains a symlink")
        if path.is_file():
            paths.append(path)
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(root).as_posix()):
        digest.update(path.relative_to(root).as_posix().encode())
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(64 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def path_entry_exists(path: Path) -> bool:
    return os.path.lexists(path)


def worker_socket_dir(work_root: Path) -> Path:
    return work_root / "r" / "ws"


def require_worker_socket_path_budget(work_root: Path) -> None:
    candidate = worker_socket_dir(work_root) / WORKER_SOCKET_FILENAME_PROBE
    if len(os.fsencode(candidate)) > LINUX_UNIX_SOCKET_PATH_MAX_BYTES:
        raise ProofFailure(
            "proof root leaves insufficient Linux Unix-socket path budget: "
            f"{len(os.fsencode(candidate))} > {LINUX_UNIX_SOCKET_PATH_MAX_BYTES} bytes"
        )


def opencode_dependency_identity(root: Path) -> tuple[str, int, int]:
    paths = [root / "package.json", root / "package-lock.json"]
    node_modules = root / "node_modules"
    if not node_modules.is_dir() or any(not path.is_file() for path in paths):
        raise ProofFailure("pinned OpenCode dependency seed is incomplete")
    paths.extend(node_modules.rglob("*"))
    digest = hashlib.sha256()
    size = 0
    count = 0
    for path in sorted(paths, key=lambda candidate: candidate.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            digest.update(b"L\0" + relative + b"\0" + os.readlink(path).encode() + b"\0")
        elif path.is_dir():
            digest.update(b"D\0" + relative + b"\0")
        elif path.is_file():
            digest.update(b"F\0" + relative + b"\0")
            size += path.stat().st_size
            count += 1
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
    return digest.hexdigest(), size, count


def prepare_opencode_dependencies(identity: dict[str, Any], destination: Path) -> None:
    source = Path(os.path.expandvars(identity["path"]))
    observed = opencode_dependency_identity(source)
    expected = (identity["sha256"], identity["size_bytes"], identity["file_count"])
    if observed != expected:
        raise ProofFailure("OpenCode dependency seed identity drifted")
    plugin_package = source / "node_modules" / "@opencode-ai" / "plugin" / "package.json"
    try:
        plugin_version = json.loads(plugin_package.read_text())["version"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError):
        raise ProofFailure("OpenCode plugin seed is invalid") from None
    if plugin_version != identity["plugin_version"]:
        raise ProofFailure("OpenCode plugin seed version drifted")
    destination.mkdir(mode=0o700)
    shutil.copy2(source / "package.json", destination / "package.json")
    shutil.copy2(source / "package-lock.json", destination / "package-lock.json")
    shutil.copytree(source / "node_modules", destination / "node_modules", symlinks=True)
    if opencode_dependency_identity(destination) != expected:
        raise ProofFailure("proof-owned OpenCode dependency copy drifted")


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def normalize_opencode_tool_schema(payload: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    tools = payload.get("tools")
    if tools is None:
        raise ProofFailure("OpenCode request omitted its tool schema")
    if not isinstance(tools, list) or not tools:
        raise ProofFailure("OpenCode tool schema is not a non-empty array")

    expected_keys = {"type", "name", "description", "parameters", "strict"}
    normalized_tools: list[dict[str, Any]] = []
    for tool in tools:
        if (
            not isinstance(tool, dict)
            or set(tool) != expected_keys
            or tool.get("type") != "function"
            or not isinstance(tool.get("name"), str)
            or not tool["name"]
            or not isinstance(tool.get("parameters"), dict)
            or ("description" in tool and not isinstance(tool["description"], str))
            or ("strict" in tool and not isinstance(tool["strict"], bool))
        ):
            raise ProofFailure("OpenCode flattened tool schema drifted")
        function = {key: value for key, value in tool.items() if key != "type"}
        normalized_tools.append({"type": "function", "function": function})

    return payload | {"tools": normalized_tools}, True


def normalize_opencode_sampling(payload: dict[str, Any]) -> dict[str, Any]:
    if any(key in payload for key in ("temperature", "top_p", "reasoning", "max_output_tokens")):
        raise ProofFailure("OpenCode sampling schema drifted")
    return payload | {
        "temperature": 1.0,
        "top_p": 0.95,
        "reasoning": {"effort": "medium"},
        "max_output_tokens": MAX_OUTPUT_TOKENS,
    }


def json_values_equal(left: Any, right: Any) -> bool:
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    if isinstance(left, int | float) and isinstance(right, int | float):
        return left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return set(left) == set(right) and all(
            json_values_equal(left[key], right[key]) for key in left
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(
            json_values_equal(left_item, right_item)
            for left_item, right_item in zip(left, right, strict=True)
        )
    return left == right


def qwen_tool_call_text(name: str, arguments: dict[str, Any]) -> str:
    identifier = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
    if identifier.fullmatch(name) is None:
        raise ProofFailure("OpenCode tool history function name drifted")
    parameters: list[str] = []
    for argument_name, value in arguments.items():
        if not isinstance(argument_name, str) or identifier.fullmatch(argument_name) is None:
            raise ProofFailure("OpenCode tool history argument name drifted")
        rendered = (
            value
            if isinstance(value, str)
            else json.dumps(value, sort_keys=True)
            .replace("<", "\\u003c")
            .replace(">", "\\u003e")
            .replace("&", "\\u0026")
            .replace("'", "\\u0027")
        )
        parameters.append(f"<parameter={argument_name}>\n{rendered}\n</parameter>\n")
    return f"<tool_call>\n<function={name}>\n" + "".join(parameters) + "</function>\n</tool_call>"


def normalize_opencode_history_message(item: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    role = item.get("role")
    content = item.get("content")
    item_type = item.get("type")
    allowed_keys = {"role", "content"} | ({"type"} if "type" in item else set())
    if (
        set(item) != allowed_keys
        or not isinstance(role, str)
        or role not in {"system", "developer", "user", "assistant"}
        or ("type" in item and item_type != "message")
    ):
        raise ProofFailure("OpenCode request message envelope drifted")
    if isinstance(content, str):
        return item, content if role == "assistant" else None
    if not isinstance(content, list) or not content:
        raise ProofFailure("OpenCode request message content drifted")

    normalized_parts: list[dict[str, Any]] = []
    texts: list[str] = []
    for part in content:
        if not isinstance(part, dict) or not isinstance(part.get("text"), str):
            raise ProofFailure("OpenCode request message content drifted")
        part_type = part.get("type")
        if not isinstance(part_type, str):
            raise ProofFailure("OpenCode request message content drifted")
        if part_type == "output_text":
            annotations = part.get("annotations", [])
            if (
                role != "assistant"
                or set(part) not in ({"type", "text"}, {"type", "text", "annotations"})
                or not isinstance(annotations, list)
                or annotations
            ):
                annotations_shape = (
                    f"list:{len(annotations)}"
                    if isinstance(annotations, list)
                    else type(annotations).__name__
                )
                raise ProofFailure(
                    "OpenCode assistant history content drifted: "
                    f"role={role};keys={','.join(sorted(part))};"
                    f"annotations={annotations_shape}"
                )
            normalized_parts.append({"type": "input_text", "text": part["text"]})
        elif part_type in {"input_text", "text"} and set(part) == {"type", "text"}:
            normalized_parts.append(part)
        else:
            raise ProofFailure("OpenCode request message content drifted")
        texts.append(part["text"])
    return item | {"content": normalized_parts}, "".join(texts) if role == "assistant" else None


def normalize_opencode_tool_history(
    payload: dict[str, Any], expected_calls: dict[str, dict[str, Any]]
) -> tuple[dict[str, Any], set[str]]:
    input_items = payload.get("input")
    if not isinstance(input_items, list):
        raise ProofFailure("OpenCode request input was not an array")
    normalized: list[dict[str, Any]] = []
    seen_calls: set[str] = set()
    index = 0
    while index < len(input_items):
        item = input_items[index]
        if not isinstance(item, dict):
            raise ProofFailure("OpenCode request input item was invalid")
        item_type = item.get("type")
        public_prefix: str | None = None
        if item_type not in {"function_call", "function_call_output"}:
            message, assistant_text = normalize_opencode_history_message(item)
            index += 1
            if (
                assistant_text is None
                or index >= len(input_items)
                or not isinstance(input_items[index], dict)
                or input_items[index].get("type") != "function_call"
            ):
                normalized.append(message)
                continue
            public_prefix = assistant_text
            item_type = "function_call"
        if item_type != "function_call":
            raise ProofFailure("OpenCode tool history ordering drifted")
        calls: list[tuple[dict[str, Any], dict[str, Any]]] = []
        while (
            index < len(input_items)
            and isinstance(input_items[index], dict)
            and input_items[index].get("type") == "function_call"
        ):
            call = input_items[index]
            if (
                set(call) != {"type", "call_id", "name", "arguments"}
                or not all(
                    isinstance(call.get(key), str) and call[key]
                    for key in ("call_id", "name", "arguments")
                )
                or call["call_id"] in seen_calls
            ):
                raise ProofFailure("OpenCode tool history schema drifted")
            try:
                arguments = json.loads(
                    call["arguments"],
                    parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
                )
            except (json.JSONDecodeError, ValueError) as error:
                raise ProofFailure("OpenCode tool history arguments were invalid") from error
            expected = expected_calls.get(call["call_id"])
            if (
                not isinstance(arguments, dict)
                or expected is None
                or expected.get("name") != call["name"]
                or not json_values_equal(expected.get("arguments"), arguments)
            ):
                raise ProofFailure("OpenCode tool history schema drifted")
            seen_calls.add(call["call_id"])
            calls.append((call, arguments))
            index += 1

        outputs: dict[str, str] = {}
        while (
            index < len(input_items)
            and isinstance(input_items[index], dict)
            and input_items[index].get("type") == "function_call_output"
        ):
            output = input_items[index]
            if (
                set(output) != {"type", "call_id", "output"}
                or output.get("call_id") not in seen_calls
                or output["call_id"] in outputs
                or not isinstance(output.get("output"), str)
                or len(output["output"]) > 100_000
            ):
                raise ProofFailure("OpenCode tool history schema drifted")
            outputs[output["call_id"]] = output["output"]
            index += 1
        call_ids = {call["call_id"] for call, _arguments in calls}
        if set(outputs) != call_ids:
            raise ProofFailure("OpenCode tool history result set drifted")
        rendered_calls: list[str] = []
        rendered_results: list[str] = []
        for call, arguments in calls:
            rendered_calls.append(qwen_tool_call_text(call["name"], arguments))
            rendered_results.append(
                f"<tool_response>\n{outputs[call['call_id']]}\n</tool_response>"
            )
        assistant_content = "\n".join(rendered_calls)
        if public_prefix:
            assistant_content = public_prefix + "\n\n" + assistant_content
        normalized.extend(
            [
                {"role": "assistant", "content": assistant_content},
                {"role": "user", "content": "\n".join(rendered_results)},
            ]
        )
    return payload | {"input": normalized}, seen_calls


def expand_opencode_tool_stream(
    body: bytes, content_type: str
) -> tuple[bytes, list[dict[str, Any]], int | None]:
    if "text/event-stream" not in content_type.lower():
        raise ProofFailure("OpenCode successful response was not an event stream")
    try:
        text = body.decode().replace("\r\n", "\n")
    except UnicodeDecodeError as error:
        raise ProofFailure("OpenCode response stream was not UTF-8") from error
    if not text.endswith("\n\n"):
        raise ProofFailure("OpenCode response stream was not terminated")
    blocks = [block for block in text.split("\n\n") if block]
    parsed: list[tuple[str, dict[str, Any]]] = []
    for block in blocks:
        event_types = [
            line.removeprefix("event: ")
            for line in block.splitlines()
            if line.startswith("event: ")
        ]
        data = "\n".join(
            line.removeprefix("data: ") for line in block.splitlines() if line.startswith("data: ")
        )
        try:
            event = json.loads(data)
        except json.JSONDecodeError as error:
            raise ProofFailure("OpenCode response stream event was invalid") from error
        if (
            len(event_types) != 1
            or not isinstance(event, dict)
            or event.get("type") != event_types[0]
        ):
            raise ProofFailure("OpenCode response stream framing drifted")
        parsed.append((block, event))

    event_types = [event.get("type") for _block, event in parsed]
    if event_types == ["response.created", "response.failed"]:
        created_response = parsed[0][1].get("response")
        failed_response = parsed[1][1].get("response")
        error = failed_response.get("error") if isinstance(failed_response, dict) else None
        response_id = created_response.get("id") if isinstance(created_response, dict) else None
        if (
            not isinstance(created_response, dict)
            or not isinstance(failed_response, dict)
            or not isinstance(response_id, str)
            or not response_id
            or response_id != failed_response.get("id")
            or created_response.get("output") not in (None, [])
            or created_response.get("output_text") not in (None, "")
            or failed_response.get("status") != "failed"
            or failed_response.get("output") not in (None, [])
            or failed_response.get("output_text") not in (None, "")
            or not isinstance(error, dict)
            or not all(isinstance(error.get(key), str) and error[key] for key in ("type", "code"))
            or not isinstance(error.get("message"), str)
        ):
            raise ProofFailure("OpenCode failed response stream schema drifted")
        return json_bytes({"error": error}), [], 400

    allowed_types = {
        "response.created",
        "response.output_text.delta",
        "response.output_text.done",
        "response.completed",
    }
    if (
        not parsed
        or parsed[0][1].get("type") != "response.created"
        or parsed[-1][1].get("type") != "response.completed"
        or any(event.get("type") not in allowed_types for _block, event in parsed)
        or sum(event.get("type") == "response.created" for _block, event in parsed) != 1
        or sum(event.get("type") == "response.completed" for _block, event in parsed) != 1
    ):
        event_types = [str(event.get("type"))[:80] for _block, event in parsed[:32]]
        terminal_response = parsed[-1][1].get("response") if parsed else None
        terminal_error = (
            terminal_response.get("error") if isinstance(terminal_response, dict) else None
        )
        error_message = terminal_error.get("message") if isinstance(terminal_error, dict) else None
        error_message = error_message if isinstance(error_message, str) else ""
        failure = {
            "event_types": event_types,
            "status": terminal_response.get("status")
            if isinstance(terminal_response, dict)
            else None,
            "error_type": terminal_error.get("type") if isinstance(terminal_error, dict) else None,
            "error_code": terminal_error.get("code") if isinstance(terminal_error, dict) else None,
            "error_message_length": len(error_message),
            "error_message_sha256": hashlib.sha256(error_message.encode()).hexdigest()
            if error_message
            else "",
        }
        raise ResponseSequenceDrift(failure)

    created_response = parsed[0][1].get("response")
    terminal = parsed[-1][1]
    response = terminal.get("response")
    if (
        not isinstance(created_response, dict)
        or not isinstance(response, dict)
        or response.get("status") != "completed"
        or not isinstance(response.get("id"), str)
        or not response["id"]
        or created_response.get("id") != response["id"]
        or not isinstance(response.get("output"), list)
    ):
        raise ProofFailure("OpenCode terminal response schema drifted")

    response_id = response["id"]
    output = response["output"]
    message: dict[str, Any] | None = None
    message_index: int | None = None
    function_calls: list[tuple[int, dict[str, Any]]] = []
    item_ids: set[str] = set()
    call_ids: set[str] = set()
    function_keys = {"type", "id", "call_id", "name", "arguments", "status"}
    for output_index, item in enumerate(output):
        if not isinstance(item, dict):
            raise ProofFailure("OpenCode terminal output item was invalid")
        if item.get("type") == "message":
            if message is not None:
                raise ProofFailure("OpenCode terminal response repeated its message item")
            message = item
            message_index = output_index
            continue
        if (
            item.get("type") != "function_call"
            or set(item) != function_keys
            or item.get("status") != "completed"
            or not all(
                isinstance(item.get(key), str) and item[key]
                for key in ("id", "call_id", "name", "arguments")
            )
            or item["id"] in item_ids
            or item["call_id"] in call_ids
        ):
            raise ProofFailure("OpenCode terminal function call schema drifted")
        item_ids.add(item["id"])
        call_ids.add(item["call_id"])
        function_calls.append((output_index, item))

    deltas = [
        event for _block, event in parsed if event.get("type") == "response.output_text.delta"
    ]
    done_events = [
        event for _block, event in parsed if event.get("type") == "response.output_text.done"
    ]
    message_text = ""
    if message is not None:
        content = message.get("content")
        if (
            message.get("role") != "assistant"
            or set(message) != {"type", "role", "content"}
            or not isinstance(content, list)
            or len(content) != 1
            or not isinstance(content[0], dict)
            or set(content[0]) != {"type", "text", "annotations"}
            or content[0].get("type") != "output_text"
            or not isinstance(content[0].get("text"), str)
            or not content[0]["text"]
            or not isinstance(content[0].get("annotations"), list)
            or len(done_events) != 1
            or not deltas
            or parsed[-2][1].get("type") != "response.output_text.done"
        ):
            raise ProofFailure("OpenCode terminal message schema drifted")
        message_text = content[0]["text"]
        if (
            any(
                event.get("response_id") != response_id
                or event.get("output_index") != message_index
                or event.get("content_index") != 0
                or not isinstance(event.get("delta"), str)
                for event in deltas
            )
            or "".join(event["delta"] for event in deltas) != message_text
            or done_events[0].get("response_id") != response_id
            or done_events[0].get("output_index") != message_index
            or done_events[0].get("content_index") != 0
            or done_events[0].get("text") != message_text
            or response.get("output_text") != message_text
        ):
            raise ProofFailure("OpenCode response text stream drifted")
    elif deltas or done_events or response.get("output_text") not in {"", None}:
        raise ProofFailure("OpenCode response emitted text without a message item")

    expanded: list[str] = []
    expanded_calls: list[dict[str, Any]] = []
    message_id = f"{response_id}-kap112-message-0"

    def append_event(event: dict[str, Any]) -> None:
        expanded.append(f"event: {event['type']}\ndata: {json_bytes(event).decode()}")

    message_started = False
    for block, event in parsed:
        event_type = event["type"]
        if event_type == "response.output_text.delta":
            if not message_started:
                append_event(
                    {
                        "type": "response.output_item.added",
                        "output_index": message_index,
                        "item": {"type": "message", "id": message_id},
                    }
                )
                message_started = True
            append_event(
                {
                    "type": "response.output_text.delta",
                    "item_id": message_id,
                    "output_index": message_index,
                    "delta": event["delta"],
                }
            )
        elif event_type == "response.output_text.done":
            append_event(
                {
                    "type": "response.output_item.done",
                    "output_index": message_index,
                    "item": {"type": "message", "id": message_id},
                }
            )
        elif event_type == "response.completed":
            for output_index, item in function_calls:
                proof_call_id = f"{response_id}-kap112-call-{output_index}"
                proof_item = item | {"id": proof_call_id, "call_id": proof_call_id}
                try:
                    arguments = json.loads(
                        item["arguments"],
                        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
                    )
                except (json.JSONDecodeError, ValueError) as error:
                    raise ProofFailure(
                        "OpenCode terminal function arguments were invalid"
                    ) from error
                if not isinstance(arguments, dict):
                    raise ProofFailure("OpenCode terminal function arguments were not an object")
                append_event(
                    {
                        "type": "response.output_item.added",
                        "output_index": output_index,
                        "item": {
                            key: value for key, value in proof_item.items() if key != "status"
                        },
                    }
                )
                append_event(
                    {
                        "type": "response.output_item.done",
                        "output_index": output_index,
                        "item": proof_item,
                    }
                )
                expanded_calls.append(
                    {
                        "call_id": proof_call_id,
                        "name": item["name"],
                        "arguments": arguments,
                    }
                )
            expanded.append(block)
        else:
            expanded.append(block)
    return ("\n\n".join(expanded) + "\n\n").encode(), expanded_calls, None


def tagged_json(output: str, marker: str, operation: str) -> dict[str, Any]:
    receipts = [
        line.removeprefix(marker) for line in output.splitlines() if line.startswith(marker)
    ]
    if len(receipts) != 1:
        raise ProofFailure(f"{operation} did not emit exactly one tagged JSON receipt")
    try:
        evidence = json.loads(receipts[0])
    except json.JSONDecodeError as error:
        raise ProofFailure(f"{operation} did not return stable JSON") from error
    if not isinstance(evidence, dict):
        raise ProofFailure(f"{operation} returned a non-object receipt")
    return evidence


def tagged_nonnegative_integer(output: str, marker: str, operation: str) -> int:
    values = [line.removeprefix(marker) for line in output.splitlines() if line.startswith(marker)]
    if len(values) != 1:
        raise ProofFailure(f"{operation} did not emit exactly one tagged integer receipt")
    if re.fullmatch(r"[0-9]+", values[0]) is None:
        raise ProofFailure(f"{operation} returned an invalid tagged integer")
    return int(values[0])


def stage_receipt_path(proof_root: Path) -> Path:
    return proof_root / STAGE_RECEIPT_FILENAME


def load_stage_receipts(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise ProofFailure("KAP-112 stage receipt is unreadable or invalid") from None
    receipts = payload.get("receipts") if isinstance(payload, dict) else None
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != 1
        or not isinstance(receipts, list)
    ):
        raise ProofFailure("KAP-112 stage receipt schema drifted")
    if any(
        not isinstance(receipt, dict) or receipt.get("ordinal") != index
        for index, receipt in enumerate(receipts, start=1)
    ):
        raise ProofFailure("KAP-112 stage receipt ordering drifted")
    return receipts


def valid_token_counts(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return value >= 0
    if isinstance(value, list):
        return bool(value) and all(valid_token_counts(item) for item in value)
    if isinstance(value, dict):
        return bool(value) and all(
            isinstance(key, str)
            and re.fullmatch(r"[a-z_]{1,40}", key) is not None
            and valid_token_counts(item)
            for key, item in value.items()
        )
    return False


def valid_api_attempts(value: Any) -> bool:
    fields = {
        "ordinal",
        "method",
        "path",
        "state",
        "status",
        "error_type",
        "error_code",
        "failure",
        "failure_detail_length",
        "failure_detail_sha256",
        "failure_evidence_sha256",
        "response_error_code",
        "response_error_message_length",
        "response_error_message_sha256",
        "response_error_type",
        "response_event_types",
        "response_sequence_observed",
        "response_status",
    }
    if not isinstance(value, list) or not value:
        return False
    for ordinal, attempt in enumerate(value, start=1):
        if not isinstance(attempt, dict) or set(attempt) != fields:
            return False
        if (
            not isinstance(attempt["ordinal"], int)
            or isinstance(attempt["ordinal"], bool)
            or attempt["ordinal"] != ordinal
        ):
            return False
        if not all(
            isinstance(attempt[field], str)
            for field in (
                "method",
                "path",
                "state",
                "error_type",
                "error_code",
                "failure",
                "failure_detail_sha256",
                "failure_evidence_sha256",
                "response_error_code",
                "response_error_message_sha256",
                "response_error_type",
                "response_status",
            )
        ):
            return False
        digest = r"sha256:[0-9a-f]{64}"
        if attempt["method"] != "POST" and re.fullmatch(digest, attempt["method"]) is None:
            return False
        if attempt["path"] != "/v1/responses" and re.fullmatch(digest, attempt["path"]) is None:
            return False
        if (
            attempt["state"] not in {"received", "rejected", "translated"}
            and re.fullmatch(digest, attempt["state"]) is None
        ):
            return False
        if any(
            value != "" and re.fullmatch(digest, value) is None
            for value in (attempt["error_type"], attempt["error_code"], attempt["failure"])
        ):
            return False
        if (
            attempt["failure_detail_sha256"] != ""
            and re.fullmatch(digest, attempt["failure_detail_sha256"]) is None
        ):
            return False
        if not isinstance(attempt["failure_detail_length"], int) or isinstance(
            attempt["failure_detail_length"], bool
        ):
            return False
        if attempt["failure_detail_length"] < 0:
            return False
        if (attempt["failure_detail_length"] == 0) != (attempt["failure_detail_sha256"] == ""):
            return False
        if attempt["failure_evidence_sha256"] != failure_evidence_sha256(
            attempt["failure"],
            attempt["failure_detail_length"],
            attempt["failure_detail_sha256"],
            attempt["response_error_message_length"],
            attempt["response_error_message_sha256"],
        ):
            return False
        response_failure = "sha256:" + hashlib.sha256(b"response_stream_drift").hexdigest()
        failure = attempt["failure"]
        if (failure == response_failure) != (attempt["failure_detail_length"] > 0):
            return False
        if not isinstance(attempt["response_sequence_observed"], bool):
            return False
        response_evidence_present = attempt["response_sequence_observed"]
        if response_evidence_present and failure != response_failure:
            return False
        known_events = {
            "response.created",
            "response.output_text.delta",
            "response.output_text.done",
            "response.completed",
            "response.failed",
        }
        if not isinstance(attempt["response_event_types"], list) or any(
            not isinstance(event, str)
            or (event not in known_events and re.fullmatch(digest, event) is None)
            for event in attempt["response_event_types"]
        ):
            return False
        if attempt["response_status"] not in {"", "completed", "failed", "in_progress"} and (
            re.fullmatch(digest, attempt["response_status"]) is None
        ):
            return False
        if any(
            value != "" and re.fullmatch(digest, value) is None
            for value in (
                attempt["response_error_type"],
                attempt["response_error_code"],
                attempt["response_error_message_sha256"],
            )
        ):
            return False
        if not isinstance(attempt["response_error_message_length"], int) or isinstance(
            attempt["response_error_message_length"], bool
        ):
            return False
        if attempt["response_error_message_length"] < 0:
            return False
        if (attempt["response_error_message_length"] == 0) != (
            attempt["response_error_message_sha256"] == ""
        ):
            return False
        if not response_evidence_present and any(
            (
                attempt["response_event_types"],
                attempt["response_status"],
                attempt["response_error_type"],
                attempt["response_error_code"],
                attempt["response_error_message_length"],
                attempt["response_error_message_sha256"],
            )
        ):
            return False
        if not isinstance(attempt["status"], int) or isinstance(attempt["status"], bool):
            return False
        if attempt["status"] < 0 or attempt["status"] > 599:
            return False
    return True


def valid_stage_evidence(evidence: dict[str, Any]) -> bool:
    for field, value in evidence.items():
        if field in STAGE_BOOLEAN_FIELDS:
            valid = isinstance(value, bool)
        elif field in STAGE_COUNT_FIELDS or field == "error_length":
            valid = isinstance(value, int) and not isinstance(value, bool) and value >= 0
        elif field in STAGE_HASH_FIELDS:
            valid = isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None
        elif field in {"usage", "finish_tokens", "observed_input_tokens"}:
            valid = valid_token_counts(value)
        elif field == "api_attempts":
            valid = valid_api_attempts(value)
        elif field == "model":
            valid = value == MODEL
        elif field == "fixture_outcome":
            valid = value == "verified"
        elif field in {"finish_reason", "error_code", "error_type"}:
            valid = (
                isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", value) is not None
            )
        else:
            valid = False
        if not valid:
            return False
    return True


def persist_stage_receipt(
    proof_root: Path,
    stage: str,
    status: str,
    evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not stage or status not in {"started", "observed", "completed", "failed"}:
        raise ProofFailure("KAP-112 stage receipt state is invalid")
    typed_evidence = evidence or {}
    allowed_fields = (
        set()
        if status == "started"
        else STAGE_OBSERVATION_FIELDS.get(stage)
        if status == "observed"
        else {"error_type", "error_length", "error_sha256"}
        if status == "failed"
        else STAGE_COMPLETION_FIELDS.get(stage)
    )
    if (
        allowed_fields is None
        or set(typed_evidence) != allowed_fields
        or not valid_stage_evidence(typed_evidence)
    ):
        raise ProofFailure("KAP-112 stage receipt evidence is not typed")
    path = stage_receipt_path(proof_root)
    temporary = path.with_name(path.name + ".tmp")
    if path_entry_exists(temporary):
        raise ProofFailure("KAP-112 stage receipt temporary path collided")
    receipts = load_stage_receipts(path)
    if status == "started":
        if (receipts and receipts[-1].get("status") in {"started", "observed"}) or any(
            receipt.get("stage") == stage for receipt in receipts
        ):
            raise ProofFailure("KAP-112 stage receipt lifecycle drifted")
    elif status == "observed" and (
        not receipts
        or receipts[-1].get("stage") != stage
        or receipts[-1].get("status") != "started"
    ):
        raise ProofFailure("KAP-112 stage receipt lifecycle drifted")
    elif stage != "runner" and (
        not receipts
        or receipts[-1].get("stage") != stage
        or receipts[-1].get("status") not in {"started", "observed"}
    ):
        raise ProofFailure("KAP-112 stage receipt lifecycle drifted")
    receipt = {
        "ordinal": len(receipts) + 1,
        "stage": stage,
        "status": status,
        "evidence": typed_evidence,
    }
    payload = {"schema_version": 1, "receipts": [*receipts, receipt]}
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(json_bytes(payload) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(proof_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        temporary.unlink(missing_ok=True)
        raise ProofFailure("unable to persist KAP-112 stage receipt") from error
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise ProofFailure("KAP-112 stage receipt permissions drifted")
    return receipt


def active_receipt_stage(proof_root: Path) -> str:
    receipts = load_stage_receipts(stage_receipt_path(proof_root))
    if receipts and receipts[-1].get("status") in {"started", "observed"}:
        stage = receipts[-1].get("stage")
        if isinstance(stage, str) and stage:
            return stage
    return "runner"


def bounded_process_diagnostic(
    result: subprocess.CompletedProcess[str], *, secrets: tuple[str, ...]
) -> str:
    def describe(name: str, value: str) -> str:
        redacted = value
        for secret in secrets:
            if secret:
                redacted = redacted.replace(secret, "[REDACTED]")
        return (
            f"{name}_length={len(value)} "
            f"{name}_sha256={hashlib.sha256(value.encode()).hexdigest()} "
            f"{name}_tail={redacted[-1000:]!r}"
        )

    return (
        f"exit={result.returncode} "
        + describe("stdout", result.stdout)
        + " "
        + describe("stderr", result.stderr)
    )


def command_result(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input_text,
        )
    except subprocess.TimeoutExpired as error:
        raise ProofFailure(f"command exceeded {timeout}s: {' '.join(command)}") from error


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    input_text: str | None = None,
) -> str:
    result = command_result(command, cwd=cwd, env=env, timeout=timeout, input_text=input_text)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ProofFailure(f"command failed ({' '.join(command)}): {detail}")
    return result.stdout.strip()


def require_failure(command: list[str], *, cwd: Path, timeout: int) -> None:
    result = command_result(command, cwd=cwd, timeout=timeout)
    if result.returncode == 0:
        raise ProofFailure(f"frozen baseline unexpectedly passed: {' '.join(command)}")


def git_identity(repo: Path) -> tuple[str, str]:
    head = run(["git", "rev-parse", "HEAD"], cwd=repo)
    tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=repo)
    status = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=repo)
    if status:
        raise ProofFailure("source worktree is not clean")
    return head, tree


def listener_hosts(port: int) -> set[str]:
    result = subprocess.run(
        ["ss", "-H", "-ltn", f"sport = :{port}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ProofFailure(f"unable to inspect listener port {port}")
    hosts: set[str] = set()
    for line in result.stdout.splitlines():
        local = line.split()[3]
        host = local.rsplit(":", 1)[0].strip("[]")
        hosts.add(host)
    return hosts


def require_loopback_listener(port: int, name: str) -> None:
    hosts = listener_hosts(port)
    if not hosts:
        raise ProofFailure(f"{name} listener is absent on port {port}")
    if not hosts <= {"127.0.0.1", "::1"}:
        raise ProofFailure(f"{name} is externally exposed on port {port}: {sorted(hosts)}")


def require_clear_port(port: int, name: str) -> None:
    hosts = listener_hosts(port)
    if hosts:
        raise ProofFailure(f"{name} port collision on {port}: {sorted(hosts)}")


def http_json(
    method: str,
    url: str,
    *,
    token: str | None = None,
    body: dict[str, Any] | None = None,
    timeout: int = 30,
) -> tuple[int, dict[str, Any]]:
    headers = {"Accept": "application/json"}
    data = None
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json_bytes(body)
    request = urllib.request.Request(url, method=method, headers=headers, data=data)
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    try:
        payload = json.loads(response.read())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProofFailure(f"non-JSON response from {url}") from error
    if not isinstance(payload, dict):
        raise ProofFailure(f"non-object response from {url}")
    return response.status, payload


def http_html(url: str, *, timeout: int = 30) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"Accept": "text/html"})
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    try:
        body = response.read().decode()
    except UnicodeDecodeError as error:
        raise ProofFailure(f"non-UTF-8 HTML response from {url}") from error
    return response.status, body


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProofFailure("fixture manifest is unreadable or invalid") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ProofFailure("fixture manifest schema drifted")
    return value


def verify_opencode(identity: dict[str, Any]) -> Path:
    path = Path(os.path.expandvars(identity["path"]))
    if not path.is_file():
        raise ProofFailure("accepted OpenCode binary is missing")
    if path.stat().st_size != identity["size_bytes"] or sha256(path) != identity["sha256"]:
        raise ProofFailure("OpenCode binary identity drifted")
    return path


def verify_manifest_identity(repo: Path, manifest: Path, head: str) -> None:
    relative = Path("scripts/fixtures/kap112/manifest.json")
    canonical = (repo / relative).resolve()
    if manifest != canonical:
        raise ProofFailure("fixture manifest must be the canonical accepted-tree artifact")
    accepted_blob = run(["git", "rev-parse", f"{head}:{relative.as_posix()}"], cwd=repo)
    working_blob = run(["git", "hash-object", str(canonical)], cwd=repo)
    if accepted_blob != working_blob:
        raise ProofFailure("fixture manifest drifted from the accepted source tree")


def verify_snapshot_manifest(repo: Path, identity: dict[str, Any]) -> None:
    snapshot = identity["model_snapshot"]
    path = (repo / snapshot["manifest_path"]).resolve()
    if repo not in path.parents or not path.is_file():
        raise ProofFailure("model snapshot manifest path is invalid")
    if sha256(path) != snapshot["manifest_sha256"]:
        raise ProofFailure("model snapshot manifest hash drifted")
    try:
        manifest = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise ProofFailure("model snapshot manifest is invalid") from None
    if (
        manifest.get("model_id") + "@" + manifest.get("revision") != identity["model"]
        or manifest.get("file_count") != snapshot["file_count"]
        or manifest.get("total_bytes") != snapshot["total_bytes"]
    ):
        raise ProofFailure("model snapshot manifest identity drifted")


def materialize_short_fixture(spec: dict[str, Any], destination: Path) -> dict[str, str]:
    destination.mkdir(mode=0o700)
    hashes: dict[str, str] = {}
    for relative, content in spec["files"].items():
        path = destination / relative
        path.write_text(content)
        hashes[relative] = sha256(path)
    run(["git", "init", "--quiet"], cwd=destination)
    run(["git", "add", "."], cwd=destination)
    run(
        [
            "git",
            "-c",
            "user.name=KAP-112 fixture",
            "-c",
            "user.email=kap112@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "fixture baseline",
        ],
        cwd=destination,
    )
    return hashes


def verify_short_fixture_outcome(repository: Path, spec: dict[str, Any]) -> None:
    observed_files: list[str] = []
    expected_directories = {
        parent.as_posix()
        for relative in spec["files"]
        for parent in Path(relative).parents
        if parent != Path(".")
    }
    for root, directories, files in os.walk(repository, followlinks=False):
        root_path = Path(root)
        for name in directories + files:
            path = root_path / name
            mode = path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ProofFailure("OpenCode fixture contains an unexpected path type")
            relative = path.relative_to(repository)
            if (
                stat.S_ISDIR(mode)
                and relative.parts[:1] != (".git",)
                and relative.as_posix() not in expected_directories
            ):
                raise ProofFailure("OpenCode fixture directory set drifted")
            if stat.S_ISREG(mode) and relative.parts[:1] != (".git",):
                observed_files.append(relative.as_posix())
    if sorted(observed_files) != sorted(spec["files"]):
        raise ProofFailure("OpenCode fixture file set drifted")
    expected_hashes = spec["initial_sha256"] | spec["expected_final_sha256"]
    observed_hashes = {relative: sha256(repository / relative) for relative in spec["files"]}
    if observed_hashes != expected_hashes:
        raise ProofFailure("OpenCode fixture outcome drifted")


def remove_short_fixture_test_state(repository: Path) -> None:
    for name in (".pytest_cache", "__pycache__"):
        path = repository / name
        if path_entry_exists(path):
            mode = path.lstat().st_mode
            if not stat.S_ISDIR(mode):
                raise ProofFailure("OpenCode fixture test state has an unexpected path type")
            shutil.rmtree(path)


def validate_short_fixture_outcome(
    repository: Path, spec: dict[str, Any], initial_hashes: dict[str, str]
) -> str:
    remove_short_fixture_test_state(repository)
    protected_after = {relative: sha256(repository / relative) for relative in spec["protected"]}
    if any(protected_after[path] != initial_hashes[path] for path in protected_after):
        raise ProofFailure("OpenCode changed a protected fixture file")
    verify_short_fixture_outcome(repository, spec)
    changed = run(["git", "diff", "--name-only"], cwd=repository).splitlines()
    if changed != spec["editable"]:
        raise ProofFailure(f"OpenCode edit scope drifted: {changed}")
    run(spec["baseline_command"], cwd=repository, timeout=spec["tool_timeout_seconds"])
    remove_short_fixture_test_state(repository)
    verify_short_fixture_outcome(repository, spec)
    short_diff = run(["git", "diff", "--binary"], cwd=repository)
    short_diff_sha256 = hashlib.sha256(short_diff.encode()).hexdigest()
    if short_diff_sha256 != spec["expected_patch_sha256"]:
        raise ProofFailure("OpenCode repair diff did not match the frozen patch")
    return short_diff_sha256


def long_context_text(spec: dict[str, Any], padding_units: int) -> str:
    if padding_units < 1:
        raise ProofFailure("long-context padding units must be positive")
    anchors = spec["anchors"]
    padding = spec["padding_atom"] * padding_units
    quarter = len(padding) // 4
    three_quarter = quarter * 3
    return (
        "\n".join(
            [
                anchors["start"],
                anchors["earlier_instruction"],
                anchors["dependency_a"],
                padding[:quarter],
                anchors["quarter"],
                anchors["dependency_b"],
                padding[quarter:three_quarter],
                anchors["three_quarter"],
                anchors["dependency_c"],
                padding[three_quarter:],
                anchors["later_instruction"],
                anchors["tool_nonce"],
                anchors["end"],
            ]
        )
        + "\n"
    )


def overflow_context_text(spec: dict[str, Any], padding_units: int) -> str:
    return long_context_text(spec, padding_units + 1)


def long_context_message(spec: dict[str, Any], context: str) -> str:
    return context + "\n" + spec["prompt"] + "\n"


def write_opencode_config(
    path: Path,
    token_file: Path,
    *,
    base_url: str = "http://127.0.0.1:4000/v1",
) -> None:
    config = {
        "$schema": "https://opencode.ai/config.json",
        "model": "openai/" + MODEL,
        "small_model": "openai/" + MODEL,
        "share": "disabled",
        "autoupdate": False,
        "compaction": {"auto": False, "prune": False, "reserved": 8192},
        "disabled_providers": [
            "anthropic",
            "google",
            "amazon-bedrock",
            "github-copilot",
        ],
        "provider": {
            "openai": {
                "name": "KAP-112 disposable Orchard",
                "options": {
                    "apiKey": "{file:" + str(token_file) + "}",
                    "baseURL": base_url,
                    "setCacheKey": False,
                    "timeout": 600000,
                },
                "models": {
                    MODEL: {
                        "name": "KAP-112 exact Qwen3.8 POC",
                        "limit": {"context": 139264, "output": 8192},
                    }
                },
            }
        },
    }
    path.write_bytes(json_bytes(config) + b"\n")
    path.chmod(0o600)


class CaptureHandler(http.server.BaseHTTPRequestHandler):
    server: CaptureServer

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("content-length", ""))
            payload = json.loads(self.rfile.read(length))
            if self.path != "/v1/responses" or not isinstance(payload, dict):
                raise ValueError
            self.server.payload = payload
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            self.server.payload = None
        finally:
            self.server.captured.set()
        body = json_bytes(
            {
                "error": {
                    "type": "invalid_request_error",
                    "code": "kap112_capture_complete",
                    "message": "offline calibration capture complete",
                }
            }
        )
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: Any) -> None:
        return


class CaptureServer(http.server.ThreadingHTTPServer):
    payload: dict[str, Any] | None = None

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), CaptureHandler)
        self.captured = threading.Event()


class OrchardProxyHandler(http.server.BaseHTTPRequestHandler):
    server: OrchardProxyServer

    def handle_one_request(self) -> None:
        self._request_index: int | None = None
        super().handle_one_request()

    def do_POST(self) -> None:
        request_index = self.server.begin_request("POST", self.path)
        self._request_index = request_index
        try:
            if self.path != "/v1/responses":
                raise ProofFailure("OpenCode request path drifted")
            length = int(self.headers.get("content-length", ""))
            if length < 0 or length > OPENCODE_REQUEST_MAX_BYTES:
                raise ProofFailure("OpenCode request content length is invalid")
            body = self.rfile.read(length)
            payload = json.loads(body)
            if not isinstance(payload, dict):
                raise ProofFailure("OpenCode request body is not an object")
            if payload.get("stream") is not True:
                raise ProofFailure("OpenCode request did not enable streaming")
            payload, translated_call_ids = normalize_opencode_tool_history(
                payload,
                self.server.tool_call_snapshot(),
            )
            payload, _translated = normalize_opencode_tool_schema(payload)
            payload = normalize_opencode_sampling(payload)
            body = json_bytes(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, ProofFailure) as error:
            self.server.update_request(
                request_index,
                state="rejected",
                status=400,
                failure=type(error).__name__,
                failure_detail=str(error),
            )
            response_body = json_bytes(
                {
                    "error": {
                        "type": "invalid_request_error",
                        "code": "kap112_opencode_schema_drift",
                        "message": "proof-only OpenCode request schema drifted",
                    }
                }
            )
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
            return
        except ValueError:
            self.server.update_request(
                request_index,
                state="rejected",
                failure="invalid_content_length",
            )
            self.send_error(400, "proof-only OpenCode request framing drifted")
            return
        connection = http.client.HTTPConnection("127.0.0.1", 4000, timeout=600)
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"connection", "content-length", "host"}
        }
        try:
            connection.request("POST", self.path, body=body, headers=headers)
            response = connection.getresponse()
            response_body = response.read()
            self.server.register_forwarded_tool_results(translated_call_ids)
        except OSError:
            self.server.update_request(
                request_index,
                state="rejected",
                failure="orchard_unavailable",
            )
            self.send_error(502, "proof-only Orchard upstream unavailable")
            return
        finally:
            connection.close()
        expanded_calls: list[dict[str, str]] = []
        response_status = response.status
        response_content_type: str | None = None
        if response.status == 200:
            try:
                response_body, expanded_calls, status_override = expand_opencode_tool_stream(
                    response_body,
                    response.getheader("content-type", ""),
                )
                if status_override is not None:
                    response_status = status_override
                    response_content_type = "application/json"
                self.server.register_tool_calls(expanded_calls)
            except ProofFailure as error:
                self.server.update_request(
                    request_index,
                    state="rejected",
                    failure="response_stream_drift",
                    failure_detail=str(error),
                    response_sequence=(
                        error.evidence if isinstance(error, ResponseSequenceDrift) else None
                    ),
                )
                self.send_error(502, "proof-only Orchard response stream drifted")
                return
        error_type = None
        error_code = None
        try:
            response_payload = json.loads(response_body)
            response_error = (
                response_payload.get("error") if isinstance(response_payload, dict) else None
            )
            if isinstance(response_error, dict):
                error_type = response_error.get("type")
                error_code = response_error.get("code")
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        self.server.update_request(
            request_index,
            state="translated",
            status=response_status,
            error_type=error_type,
            error_code=error_code,
            tool_history_translations=len(translated_call_ids),
            tool_stream_expansions=len(expanded_calls),
        )
        self.send_response(response_status)
        for key, value in response.getheaders():
            if key.lower() not in {
                "connection",
                "content-length",
                "transfer-encoding",
                "content-type" if response_content_type is not None else "",
            }:
                self.send_header(key, value)
        if response_content_type is not None:
            self.send_header("content-type", response_content_type)
        self.send_header("content-length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    def do_GET(self) -> None:
        self._reject_method()

    def do_PUT(self) -> None:
        self._reject_method()

    def do_PATCH(self) -> None:
        self._reject_method()

    def do_DELETE(self) -> None:
        self._reject_method()

    def do_HEAD(self) -> None:
        self._reject_method()

    def do_OPTIONS(self) -> None:
        self._reject_method()

    def _reject_method(self) -> None:
        request_index = self.server.begin_request(self.command, self.path)
        self._request_index = request_index
        self.server.update_request(
            request_index,
            state="rejected",
            failure="unsupported_method",
        )
        self.send_error(405, "proof-only OpenCode request method drifted")

    def send_error(
        self,
        code: int,
        message: str | None = None,
        explain: str | None = None,
    ) -> None:
        if self._request_index is None:
            self._request_index = self.server.begin_request("rejected", "")
            self.server.update_request(
                self._request_index,
                state="rejected",
                failure="http_protocol_drift",
            )
        self.server.update_request(self._request_index, status=code)
        super().send_error(
            code,
            "proof-only OpenCode request rejected",
            "proof-only OpenCode request framing or method drifted",
        )

    def log_message(self, _format: str, *_args: Any) -> None:
        return


class OrchardProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), OrchardProxyHandler)
        self.requests: list[dict[str, Any]] = []
        self.tool_calls: dict[str, dict[str, Any]] = {}
        self.forwarded_tool_results: set[str] = set()
        self.requests_lock = threading.Lock()

    def begin_request(self, method: str, path: str) -> int:
        with self.requests_lock:
            self.requests.append({"method": method, "path": path, "state": "received"})
            return len(self.requests) - 1

    def update_request(self, request_index: int, **evidence: Any) -> None:
        with self.requests_lock:
            self.requests[request_index] |= evidence

    def request_snapshot(self) -> list[dict[str, Any]]:
        with self.requests_lock:
            return [request.copy() for request in self.requests]

    def request_count(self) -> int:
        with self.requests_lock:
            return len(self.requests)

    def typed_request_attempts(self, start: int) -> list[dict[str, Any]]:
        with self.requests_lock:
            requests = [request.copy() for request in self.requests[start:]]
        return [
            typed_request_attempt(request, ordinal) for ordinal, request in enumerate(requests, 1)
        ]

    def tool_call_snapshot(self) -> dict[str, dict[str, Any]]:
        with self.requests_lock:
            return {call_id: call.copy() for call_id, call in self.tool_calls.items()}

    def register_tool_calls(self, calls: list[dict[str, Any]]) -> None:
        with self.requests_lock:
            for call in calls:
                call_id = call["call_id"]
                if call_id in self.tool_calls:
                    raise ProofFailure("OpenCode proof-local tool call identity repeated")
                self.tool_calls[call_id] = {
                    "name": call["name"],
                    "arguments": call["arguments"],
                }

    def register_forwarded_tool_results(self, call_ids: set[str]) -> None:
        with self.requests_lock:
            self.forwarded_tool_results.update(call_ids)

    def tool_result_identity_snapshot(self) -> tuple[set[str], set[str]]:
        with self.requests_lock:
            return set(self.tool_calls), self.forwarded_tool_results.copy()


def redacted_attempt_value(value: Any, allowed: set[str] | None = None) -> str:
    if value is None or value == "":
        return ""
    rendered = str(value)
    if allowed is not None and rendered in allowed:
        return rendered
    return "sha256:" + hashlib.sha256(rendered.encode()).hexdigest()


def failure_evidence_sha256(
    failure: str,
    detail_length: int,
    detail_sha256: str,
    response_message_length: int = 0,
    response_message_sha256: str = "",
) -> str:
    if not any(
        (
            failure,
            detail_length,
            detail_sha256,
            response_message_length,
            response_message_sha256,
        )
    ):
        return ""
    evidence = {
        "failure": failure,
        "failure_detail_length": detail_length,
        "failure_detail_sha256": detail_sha256,
        "response_error_message_length": response_message_length,
        "response_error_message_sha256": response_message_sha256,
    }
    return "sha256:" + hashlib.sha256(json_bytes(evidence)).hexdigest()


def typed_response_sequence(request: dict[str, Any]) -> dict[str, Any]:
    sequence = request.get("response_sequence")
    if not isinstance(sequence, dict):
        return {
            "response_event_types": [],
            "response_sequence_observed": False,
            "response_status": "",
            "response_error_type": "",
            "response_error_code": "",
            "response_error_message_length": 0,
            "response_error_message_sha256": "",
        }
    known_events = {
        "response.created",
        "response.output_text.delta",
        "response.output_text.done",
        "response.completed",
        "response.failed",
    }
    events = sequence.get("event_types")
    typed_events = (
        [redacted_attempt_value(event, known_events) for event in events]
        if isinstance(events, list)
        else []
    )
    message_length = sequence.get("error_message_length")
    message_length = (
        message_length
        if isinstance(message_length, int) and not isinstance(message_length, bool)
        else 0
    )
    message_sha256 = sequence.get("error_message_sha256")
    message_sha256 = (
        "sha256:" + message_sha256
        if isinstance(message_sha256, str) and re.fullmatch(r"[0-9a-f]{64}", message_sha256)
        else ""
    )
    return {
        "response_event_types": typed_events,
        "response_sequence_observed": True,
        "response_status": redacted_attempt_value(
            sequence.get("status"), {"completed", "failed", "in_progress"}
        ),
        "response_error_type": redacted_attempt_value(sequence.get("error_type")),
        "response_error_code": redacted_attempt_value(sequence.get("error_code")),
        "response_error_message_length": message_length,
        "response_error_message_sha256": message_sha256,
    }


def typed_request_attempt(request: dict[str, Any], ordinal: int) -> dict[str, Any]:
    status = request.get("status", 0)
    if not isinstance(status, int) or isinstance(status, bool) or status < 0 or status > 599:
        status = 0
    failure_detail = str(request.get("failure_detail", ""))
    failure = redacted_attempt_value(request.get("failure"))
    failure_detail_sha256 = redacted_attempt_value(failure_detail)
    response_sequence = typed_response_sequence(request)
    return {
        "ordinal": ordinal,
        "method": redacted_attempt_value(request.get("method"), {"POST"}),
        "path": redacted_attempt_value(request.get("path"), {"/v1/responses"}),
        "state": redacted_attempt_value(
            request.get("state"), {"received", "rejected", "translated"}
        ),
        "status": status,
        "error_type": redacted_attempt_value(request.get("error_type")),
        "error_code": redacted_attempt_value(request.get("error_code")),
        "failure": failure,
        "failure_detail_length": len(failure_detail),
        "failure_detail_sha256": failure_detail_sha256,
        "failure_evidence_sha256": failure_evidence_sha256(
            failure,
            len(failure_detail),
            failure_detail_sha256,
            response_sequence["response_error_message_length"],
            response_sequence["response_error_message_sha256"],
        ),
    } | response_sequence


def persist_request_observation(
    proof_root: Path,
    stage: str,
    proxy: OrchardProxyServer,
    request_start: int,
    model_turn_count: int,
) -> int:
    attempts = proxy.typed_request_attempts(request_start)
    persist_stage_receipt(
        proof_root,
        stage,
        "observed",
        {
            "api_attempts": attempts,
            "api_requests": len(attempts),
            "model_turn_count": model_turn_count,
        },
    )
    return len(attempts)


def persist_opencode_attempts_before_validation(
    proof_root: Path,
    stage: str,
    proxy: OrchardProxyServer,
    request_start: int,
    raw: str,
) -> tuple[int, int]:
    model_turn_count = observed_model_turn_count(raw)
    request_count = persist_request_observation(
        proof_root,
        stage,
        proxy,
        request_start,
        model_turn_count,
    )
    if request_count != model_turn_count:
        raise ProofFailure(f"OpenCode {stage.replace('_', '-')} smoke made an automatic API retry")
    return request_count, model_turn_count


@contextlib.contextmanager
def measured_orchard_proxy() -> Iterator[OrchardProxyServer]:
    server = OrchardProxyServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def opencode_proof_env(
    root: Path,
    config_path: Path,
    base: dict[str, str],
    *,
    config_home: Path | None = None,
) -> dict[str, str]:
    locations = {
        "XDG_CONFIG_HOME": config_home or root / "xdg-config",
        "XDG_DATA_HOME": root / "xdg-data",
        "XDG_STATE_HOME": root / "xdg-state",
        "XDG_CACHE_HOME": root / "xdg-cache",
    }
    for directory in locations.values():
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    client_environment = {
        key: value for key, value in bounded_environment(base).items() if not key.startswith("PG")
    }
    return (
        client_environment
        | {key: str(value) for key, value in locations.items()}
        | {
            "OPENCODE_CONFIG": str(config_path),
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_SHARE": "1",
        }
    )


def run_opencode(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.PIPE if input_text is not None else None,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input=input_text, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        stop_process_group(process)
        process.communicate()
        raise ProofFailure(f"command exceeded {timeout}s: {' '.join(command)}") from error
    finally:
        stop_process_group(process)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def capture_opencode_request(
    opencode: Path,
    *,
    root: Path,
    repository: Path,
    message: str,
    base_env: dict[str, str],
    config_home: Path | None = None,
    timeout: float = 60,
) -> dict[str, Any]:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    server = CaptureServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    config_path = root / "opencode.json"
    token_file = root / "capture-token"
    token_file.write_text("capture-only-not-a-live-credential")
    token_file.chmod(0o600)
    write_opencode_config(
        config_path,
        token_file,
        base_url=f"http://127.0.0.1:{server.server_port}/v1",
    )
    environment = opencode_proof_env(
        root / "identity", config_path, base_env, config_home=config_home
    )
    captured = False
    process: subprocess.Popen[bytes] | None = None
    stderr = b""
    try:
        process = subprocess.Popen(
            [
                str(opencode),
                "run",
                "--format",
                "json",
                "--title",
                "KAP-112 frozen long context",
                "--dir",
                str(repository),
            ],
            cwd=repository,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            _stdout, stderr = process.communicate(input=message.encode(), timeout=timeout)
        except subprocess.TimeoutExpired as error:
            stop_process_group(process)
            process.communicate()
            raise ProofFailure("OpenCode offline calibration timed out") from error
        captured = server.captured.is_set()
    finally:
        if process is not None:
            stop_process_group(process)
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    if process is None:
        raise ProofFailure("OpenCode offline calibration did not start")
    if not captured:
        detail = stderr.decode(errors="replace")[-500:].strip()
        suffix = f": {detail}" if detail else ""
        raise ProofFailure(f"OpenCode offline calibration did not emit a request{suffix}")
    if server.payload is None:
        raise ProofFailure("OpenCode offline calibration request was invalid")
    if "prompt_cache_key" in server.payload:
        raise ProofFailure("OpenCode prompt cache key remained enabled")
    payload, _translated = normalize_opencode_tool_schema(server.payload)
    return normalize_opencode_sampling(payload)


def count_captured_request(repo: Path, bundle: Path, request: dict[str, Any]) -> int:
    input_items = normalize_responses_input(request)
    template_path = bundle / "chat_template.jinja"
    registration_template_path = bundle / "reasoning_contract_template.json"
    try:
        registration = json.loads(registration_template_path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise ProofFailure("proof bundle reasoning registration is missing or invalid") from None
    registration["model_artifact_digest"] = bundle_tree_sha256(bundle)
    effective_contract = {
        "mode": "negotiated",
        "model_artifact_digest": registration["model_artifact_digest"],
        "chat_template_digest": registration["chat_template_digest"],
        "render_contract": registration["render_contract"],
        "render_contract_version": registration["render_contract_version"],
        "parser_family": registration["parser_family"],
        "parser_version": registration["parser_version"],
        "runtime_contract_version": registration["runtime_contract_version"],
        "event_binding_version": registration["event_binding_version"],
    }
    tokenization_request: dict[str, Any] = {
        "contract_version": 4,
        "command": "render_and_count_reasoning",
        "assets": {
            "tokenizer_kind": "huggingface_tokenizer_json",
            "tokenizer_path": str(bundle / "tokenizer.json"),
            "tokenizer_config_path": str(bundle / "tokenizer_config.json"),
            "chat_template_path": str(template_path),
            "model_artifact_digest": registration["model_artifact_digest"],
            "chat_template_digest": registration["chat_template_digest"],
        },
        "request": {
            "input_items": input_items,
            "tools": request.get("tools"),
            "tool_choice": request.get("tool_choice"),
            "reasoning": {
                "generation_policy": "enabled",
                "projection": "final_only",
                "reasoning_effort": "medium",
                "source": "explicit_public",
                "effective_contract": effective_contract,
            },
        },
    }
    with tempfile.TemporaryDirectory(prefix="orchard-kap112-reasoning-") as temp_dir:
        registration_path = Path(temp_dir) / "registration.json"
        registration_path.write_bytes(json_bytes(registration))
        registration_path.chmod(0o600)
        environment = bounded_environment(os.environ.copy()) | {
            "UV_OFFLINE": "1",
            "ORCHARD_KAP112_REASONING_CONTRACT": str(registration_path),
        }
        output = run(
            [
                "mise",
                "exec",
                "--",
                "uv",
                "run",
                "--offline",
                "--frozen",
                "--directory",
                "native/orchard_tokenizer",
                "orchard-tokenizer",
            ],
            cwd=repo,
            env=environment,
            timeout=120,
            input_text=json.dumps(tokenization_request, separators=(",", ":")),
        )
    try:
        response = json.loads(output)
        count = response["result"]["input_token_count"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise ProofFailure("exact tokenizer rejected the OpenCode calibration request") from None
    if not isinstance(count, int) or isinstance(count, bool):
        raise ProofFailure("exact tokenizer returned an invalid input count")
    if response["result"].get("reasoning") != tokenization_request["request"]["reasoning"]:
        raise ProofFailure("exact tokenizer did not prove the effective medium contract")
    return count


def normalize_responses_input(request: dict[str, Any]) -> list[dict[str, Any]]:
    input_items = request.get("input")
    if not isinstance(input_items, list):
        raise ProofFailure("OpenCode calibration request omitted Responses input items")
    normalized: list[dict[str, Any]] = []
    instructions = request.get("instructions")
    if instructions is not None:
        if not isinstance(instructions, str):
            raise ProofFailure("OpenCode calibration instructions are invalid")
        normalized.append({"role": "system", "content": instructions})
    for item in input_items:
        if not isinstance(item, dict) or not isinstance(item.get("role"), str):
            raise ProofFailure("OpenCode calibration input item is invalid")
        content = item.get("content")
        if isinstance(content, str):
            normalized_content: str | list[dict[str, str]] = content
        elif isinstance(content, list):
            normalized_content = []
            for part in content:
                if (
                    not isinstance(part, dict)
                    or part.get("type") not in {"input_text", "text"}
                    or not isinstance(part.get("text"), str)
                ):
                    raise ProofFailure("OpenCode calibration content part is unsupported")
                normalized_content.append({"type": "text", "text": part["text"]})
        else:
            raise ProofFailure("OpenCode calibration content is invalid")
        normalized.append({"role": item["role"], "content": normalized_content})
    return normalized


def tokenizer_asset_hashes(bundle: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for name in TOKENIZER_ASSETS:
        path = bundle / name
        if not path.is_file():
            raise ProofFailure(f"snapshot tokenizer asset is absent: {name}")
        hashes[name] = sha256(path)
    return hashes


def find_padding_units(counter: Any, target: int = 131_072) -> int:
    low = 1
    high = target
    while low <= high:
        middle = (low + high) // 2
        count = counter(middle)
        if count == target:
            return middle
        if count < target:
            low = middle + 1
        else:
            high = middle - 1
    raise ProofFailure(f"frozen padding recipe cannot produce exactly {target} rendered tokens")


def calibrate_long_context(
    opencode: Path,
    *,
    repo: Path,
    work_root: Path,
    bundle: Path,
    spec: dict[str, Any],
    base_env: dict[str, str],
    config_home: Path,
) -> tuple[int, Path]:
    calibration_root = work_root / "calibration"
    calibration_root.mkdir(mode=0o700)
    counts: dict[int, int] = {}

    def count(units: int) -> int:
        if units in counts:
            return counts[units]
        attempt = calibration_root / str(units)
        attempt.mkdir(mode=0o700)
        attachment = attempt / "long-context.txt"
        attachment.write_text(long_context_text(spec, units))
        request = capture_opencode_request(
            opencode,
            root=attempt,
            repository=work_root,
            message=long_context_message(spec, attachment.read_text()),
            base_env=base_env,
            config_home=config_home,
        )
        counts[units] = count_captured_request(repo, bundle, request)
        return counts[units]

    units = find_padding_units(count)
    if count(units + 1) != 131_073:
        raise ProofFailure("frozen overflow atom is not exactly one provider token")
    long_path = work_root / "long-context.txt"
    long_path.write_text(long_context_text(spec, units))
    shutil.rmtree(calibration_root)
    return units, long_path


def validate_response(payload: dict[str, Any], expected_text: str) -> dict[str, Any]:
    if payload.get("object") != "response" or payload.get("status") != "completed":
        raise ProofFailure("direct API response did not complete")
    if payload.get("model") != MODEL:
        raise ProofFailure(f"direct API model identity drifted: {payload.get('model')!r}")
    output_text = payload.get("output_text", "")
    if not isinstance(output_text, str):
        raise ProofFailure("direct API output was not text")
    normalized_output = output_text.strip()
    if normalized_output != expected_text:
        digest = hashlib.sha256(normalized_output.encode()).hexdigest()
        raise ProofFailure(
            "direct API output drifted: "
            f"length={len(normalized_output)} sha256={digest} "
            f"preview={normalized_output[:160]!r}"
        )
    usage = payload.get("usage")
    if not isinstance(usage, dict) or not all(
        isinstance(usage.get(key), int) for key in ("input_tokens", "output_tokens", "total_tokens")
    ):
        raise ProofFailure("direct API usage is absent or invalid")
    if usage["total_tokens"] != usage["input_tokens"] + usage["output_tokens"]:
        raise ProofFailure("direct API usage arithmetic is invalid")
    return {"request_id": payload.get("id"), "model": payload["model"], "usage": usage}


def validate_overflow(status: int, payload: dict[str, Any], spec: dict[str, Any]) -> None:
    error = payload.get("error")
    if (
        status != spec["expected_http_status"]
        or not isinstance(error, dict)
        or error.get("type") != spec["expected_error_type"]
        or error.get("code") != spec["expected_error_code"]
    ):
        raise ProofFailure("overflow request did not fail with the frozen contract")


def parse_opencode_events(raw: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise ProofFailure("OpenCode emitted a non-JSON event") from error
        if not isinstance(event, dict):
            raise ProofFailure("OpenCode emitted a non-object event")
        events.append(event)
    if not events:
        raise ProofFailure("OpenCode emitted no events")
    return events


def event_part(event: dict[str, Any]) -> dict[str, Any]:
    part = event.get("part")
    return part if isinstance(part, dict) else {}


def terminal_assistant_text(events: list[dict[str, Any]]) -> str:
    final_step = max(
        (index for index, event in enumerate(events) if event.get("type") == "step_start"),
        default=0,
    )
    texts = [
        event_part(event).get("text")
        for event in events[final_step:]
        if event.get("type") == "text"
    ]
    if not texts or not all(isinstance(text, str) for text in texts):
        raise ProofFailure("OpenCode emitted no typed terminal assistant text")
    return "".join(texts).strip()


def opencode_event_summary(
    raw: str, *, exact_input_tokens: int | None = None, maximum_turns: int
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    events = parse_opencode_events(raw)
    turns = sum(event.get("type") == "step_start" for event in events)
    if turns < 1 or turns > maximum_turns:
        raise ProofFailure(f"OpenCode model-turn bound was not satisfied: {turns}")
    finishes = [event_part(event) for event in events if event.get("type") == "step_finish"]
    if not finishes or not isinstance(finishes[-1].get("reason"), str):
        raise ProofFailure("OpenCode stream did not close with a typed finish reason")
    input_tokens = []
    for finish in finishes:
        tokens = finish.get("tokens")
        value = tokens.get("input") if isinstance(tokens, dict) else None
        if isinstance(value, int) and not isinstance(value, bool):
            input_tokens.append(value)
    if exact_input_tokens is not None and exact_input_tokens not in input_tokens:
        raise ProofFailure(
            "OpenCode provider usage did not prove exactly "
            f"{exact_input_tokens} rendered input tokens"
        )
    tool_events = [event for event in events if event.get("type") == "tool_use"]
    reasoning_events = [event for event in events if event.get("type") == "reasoning"]
    if reasoning_events:
        raise ProofFailure("proof-only parser exposed reasoning content to OpenCode")
    summary = {
        "event_count": len(events),
        "model_turn_count": turns,
        "tool_event_count": len(tool_events),
        "reasoning_event_count": len(reasoning_events),
        "finish_reason": finishes[-1]["reason"],
        "finish_tokens": [finish.get("tokens") for finish in finishes],
        "observed_input_tokens": sorted(set(input_tokens)),
    }
    return events, summary


def observed_model_turn_count(raw: str) -> int:
    turns = 0
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("type") == "step_start":
            turns += 1
    return turns


def tool_evidence(event: dict[str, Any]) -> tuple[str, str, str, str, int | None]:
    part = event_part(event)
    state = part.get("state")
    if not isinstance(state, dict):
        return "", "", "", "", None
    tool_input = state.get("input")
    metadata = state.get("metadata")
    return (
        str(part.get("tool", "")),
        str(state.get("status", "")),
        str(tool_input.get("command", "")) if isinstance(tool_input, dict) else "",
        str(state.get("output", "")),
        metadata.get("exit") if isinstance(metadata, dict) else None,
    )


def validate_short_events(
    raw: str,
    maximum_turns: int,
    maximum_tools: int,
    *,
    secrets: tuple[str, ...] = (),
) -> dict[str, Any]:
    events, summary = opencode_event_summary(raw, maximum_turns=maximum_turns)
    tool_events = [event for event in events if event.get("type") == "tool_use"]
    evidence = [tool_evidence(event) for event in tool_events]
    if not tool_events or len(tool_events) > maximum_tools:
        observed: dict[str, int] = {}
        for tool, status, _command, _output, _exit in evidence:
            key = f"{tool or 'unknown'}:{status or 'unknown'}"
            observed[key] = observed.get(key, 0) + 1
        text = "".join(
            part["text"]
            for event in events
            if event.get("type") == "text"
            and isinstance((part := event_part(event)).get("text"), str)
        )
        redacted_tail = text[-500:]
        for secret in secrets:
            if secret:
                redacted_tail = redacted_tail.replace(secret, "[REDACTED]")
        raise ProofFailure(
            "OpenCode tool-event bound was not satisfied: "
            f"count={len(tool_events)} maximum={maximum_tools} observed={observed} "
            f"finish_reason={summary['finish_reason']!r} "
            f"finish_tokens={summary['finish_tokens']!r} "
            f"text_length={len(text)} text_sha256={hashlib.sha256(text.encode()).hexdigest()} "
            f"text_tail={redacted_tail!r}"
        )
    completed_tools = [item for item in evidence if item[1] == "completed"]
    if not completed_tools:
        raise ProofFailure("OpenCode emitted no completed client-side tool event")
    summary_text = terminal_assistant_text(events).strip()
    if not summary_text:
        raise ProofFailure("OpenCode emitted no nonempty terminal summary")
    summary["completed_tool_event_count"] = len(completed_tools)
    summary["terminal_text_sha256"] = hashlib.sha256(summary_text.encode()).hexdigest()
    return summary


def run_short_opencode(
    *,
    opencode: Path,
    repository: Path,
    environment: dict[str, str],
    spec: dict[str, Any],
    token: str,
    api_proxy: OrchardProxyServer | None = None,
) -> str:
    result = run_opencode(
        [
            str(opencode),
            "run",
            "--format",
            "json",
            "--title",
            "KAP-112 Orchard API client proof",
            "--dir",
            str(repository),
            spec["prompt"],
        ],
        cwd=repository,
        env=environment,
        timeout=spec["wall_timeout_seconds"],
    )
    if result.returncode != 0:
        proxy_failure: dict[str, Any] = {}
        if api_proxy is not None:
            requests = api_proxy.request_snapshot()
            if requests:
                proxy_failure = {
                    key: requests[-1][key]
                    for key in ("state", "failure", "failure_detail")
                    if key in requests[-1]
                }
        raise ProofFailure(
            "OpenCode short API-client proof exited unsuccessfully: "
            + bounded_process_diagnostic(result, secrets=(token,))
            + f" proxy_failure={json.dumps(proxy_failure, sort_keys=True)}"
        )
    return result.stdout.rstrip("\n")


def validate_long_events(raw: str, spec: dict[str, Any], exact_input_tokens: int) -> dict[str, Any]:
    events, summary = opencode_event_summary(
        raw,
        exact_input_tokens=exact_input_tokens,
        maximum_turns=spec["max_model_turns"],
    )
    if summary["tool_event_count"] > spec["max_tool_calls"]:
        raise ProofFailure("OpenCode long-context tool-event bound was not satisfied")
    try:
        answer = json.loads(terminal_assistant_text(events))
    except json.JSONDecodeError as error:
        raise ProofFailure("OpenCode terminal long-context answer was not exact JSON") from error
    if not isinstance(answer, dict):
        encoded = json_bytes(answer)
        diagnostic = {
            "type": type(answer).__name__,
            "length": len(answer) if isinstance(answer, (str, list, dict)) else 0,
            "sha256": hashlib.sha256(encoded).hexdigest(),
        }
        raise ProofFailure(
            "OpenCode terminal long-context answer was not an object: "
            + json.dumps(diagnostic, sort_keys=True, separators=(",", ":"))
        )
    expected = spec["expected_answer"]
    expected_object = {
        "anchors": expected["anchors"],
        "instruction": expected["instruction"],
        "dependency_result": expected["dependency_result"],
        "tool_nonce": expected["tool_nonce"],
    }
    if answer != expected_object or list(answer) != list(expected_object):
        fields: dict[str, Any] = {}
        for key in expected_object:
            value = answer.get(key)
            encoded = json_bytes(value)
            fields[key] = {
                "exact": value == expected_object[key],
                "type": type(value).__name__,
                "length": len(value) if isinstance(value, (str, list, dict)) else 0,
                "sha256": hashlib.sha256(encoded).hexdigest(),
            }
            if isinstance(value, int) and not isinstance(value, bool):
                fields[key]["integer"] = value
        diagnostic = {
            "keys": list(answer),
            "fields": fields,
        }
        raise ProofFailure(
            "OpenCode terminal long-context answer drifted: "
            + json.dumps(diagnostic, sort_keys=True, separators=(",", ":"))
        )
    summary["terminal_answer"] = answer
    return summary


def validate_overflow_events(raw: str, spec: dict[str, Any]) -> dict[str, Any]:
    events = parse_opencode_events(raw)
    error_events = [event for event in events if event.get("type") == "error"]
    if not error_events:
        raise ProofFailure("OpenCode overflow did not emit a typed error")
    errors: list[dict[str, Any]] = []
    for event in error_events:
        error = event.get("error")
        if not isinstance(error, dict):
            raise ProofFailure("OpenCode overflow error lacked structured evidence")
        data = error.get("data")
        response_body = data.get("responseBody") if isinstance(data, dict) else None
        if not isinstance(response_body, str):
            raise ProofFailure("OpenCode overflow error omitted the provider response")
        try:
            provider_response = json.loads(response_body)
        except json.JSONDecodeError:
            raise ProofFailure(
                "OpenCode overflow provider response was invalid: "
                + json.dumps(
                    {
                        "body_length": len(response_body),
                        "body_sha256": hashlib.sha256(response_body.encode()).hexdigest(),
                        "parsed": False,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
            ) from None
        provider_error = (
            provider_response.get("error") if isinstance(provider_response, dict) else None
        )
        if not isinstance(provider_error, dict):
            raise ProofFailure(
                "OpenCode overflow provider error was invalid: "
                + json.dumps(
                    {
                        "response_type": type(provider_response).__name__,
                        "response_keys": (
                            sorted(provider_response) if isinstance(provider_response, dict) else []
                        ),
                        "error_type": type(provider_error).__name__,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
        errors.append(provider_error)
    if any(
        error.get("type") != spec["expected_error_type"]
        or error.get("code") != spec["expected_error_code"]
        for error in errors
    ):
        raise ProofFailure("OpenCode overflow error type or code drifted")
    if len({json.dumps(error, sort_keys=True) for error in errors}) != 1:
        raise ProofFailure("OpenCode overflow emitted conflicting typed errors")
    if any(event.get("type") in {"step_start", "tool_use", "text"} for event in events):
        raise ProofFailure("OpenCode overflow advanced beyond bounded refusal")
    return {
        "event_count": len(events),
        "duplicate_event_count": len(error_events),
        "error_code": errors[0]["code"],
    }


def validate_overflow_proxy_evidence(
    evidence: list[dict[str, Any]], spec: dict[str, Any]
) -> dict[str, Any]:
    expected_transport = {
        "method": "POST",
        "path": "/v1/responses",
        "state": "translated",
        "status": spec["expected_http_status"],
        "tool_history_translations": 0,
        "tool_stream_expansions": 0,
    }
    observed = evidence[0] if len(evidence) == 1 else {}
    if (
        any(observed.get(key) != value for key, value in expected_transport.items())
        or observed.get("error_type") not in {None, spec["expected_error_type"]}
        or observed.get("error_code") not in {None, spec["expected_error_code"]}
    ):
        raise ProofFailure("overflow HTTP refusal evidence drifted")
    return observed


def durable_request_count(repo: Path, env: dict[str, str]) -> int:
    expression = """
Application.ensure_all_started(:ecto_sql)
{:ok, repo} = Orchard.Repo.start_link()
%{rows: [[count]]} = Ecto.Adapters.SQL.query!(Orchard.Repo, "select count(*) from requests", [])
IO.puts("KAP112_REQUEST_COUNT=" <> Integer.to_string(count))
GenServer.stop(repo)
"""
    output = run(
        ["mise", "exec", "--", "mix", "run", "--no-start", "-e", expression],
        cwd=repo,
        env=env,
        timeout=60,
    )
    return tagged_nonnegative_integer(output, "KAP112_REQUEST_COUNT=", "durable request count")


def request_inspection_expression(request_id: str) -> str:
    encoded_request_id = json.dumps(request_id)
    return f"""
alias OrchardCLI.Commands.Requests
{{:ok, json}} = Requests.run(["inspect", {encoded_request_id}, "--json"])
IO.puts("KAP112_REQUEST_INSPECT_JSON=" <> Jason.encode!(Jason.decode!(json)))
"""


def logical_unload(repo: Path, env: dict[str, str]) -> dict[str, Any]:
    expression = """
alias Orchard.Cluster.V1.UnloadModelRequest
alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
model_id = "Qwen/Qwen3.8-27B"
version = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
{:ok, _apps} = Application.ensure_all_started(:grpc)
{:ok, channel} = Client.connect(host: "127.0.0.1", port: 50_071)
{:ok, ack} = Client.unload_model(channel, %UnloadModelRequest{
  model_id: model_id,
  version: version,
  force: false,
  evict: false
})
{:ok, status} = Client.status(channel)
loaded = Enum.any?(status.loaded_models, &(&1.model_id == model_id and &1.version == version))
:ok = Client.disconnect(channel)
IO.puts("KAP112_LOGICAL_UNLOAD_JSON=" <> Jason.encode!(%{
  ack: ack.ok,
  message: ack.message,
  still_loaded: loaded
}))
"""
    output = run(
        ["mise", "exec", "--", "mix", "run", "--no-start", "-e", expression],
        cwd=repo,
        env=env,
        timeout=60,
    )
    evidence = tagged_json(output, "KAP112_LOGICAL_UNLOAD_JSON=", "logical unload")
    if evidence.get("ack") is not True:
        raise ProofFailure("Node Runtime did not acknowledge logical unload")
    if evidence.get("still_loaded") is not False:
        raise ProofFailure("Node Runtime still reported the model after logical unload")
    return evidence


def logical_load(repo: Path, env: dict[str, str]) -> dict[str, Any]:
    expression = """
alias Orchard.Cluster.V1.EnsureModelLoadedRequest
alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
alias Orchard.Models.Model
model_id = "Qwen/Qwen3.8-27B"
version = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
{:ok, _apps} = Application.ensure_all_started(:grpc)
Application.ensure_all_started(:ecto_sql)
{:ok, repo} = Orchard.Repo.start_link()
model = Orchard.Repo.get_by!(Model, model_id: model_id, version: version)
artifact_uri = URI.parse(model.artifact_uri)
if artifact_uri.scheme != "file" or artifact_uri.host not in [nil, ""] or
     Path.type(artifact_uri.path || "") != :absolute do
  raise "KAP-112 artifact URI must be an absolute local file URI"
end
{:ok, channel} = Client.connect(host: "127.0.0.1", port: 50_071)
{:ok, before_status} = Client.status(channel)
node_id = before_status.node_metadata.node_id
{:ok, response} = Client.ensure_model_loaded(channel, %EnsureModelLoadedRequest{
  node_id: node_id,
  model_id: model_id,
  version: version,
  artifact_sha256: model.artifact_sha256,
  preload: true,
  deadline_unix_ms: System.system_time(:millisecond) + 120_000,
  artifact_source_uri: model.artifact_uri
}, timeout: 120_000)
{:ok, after_status} = Client.status(channel)
loaded = Enum.any?(after_status.loaded_models, &(&1.model_id == model_id and &1.version == version))
:ok = Client.disconnect(channel)
GenServer.stop(repo)
IO.puts("KAP112_LOGICAL_LOAD_JSON=" <> Jason.encode!(%{
  already_loaded: response.already_loaded,
  failure_code: response.failure_code,
  loaded: loaded,
  model: model_id <> "@" <> version,
  placement_state: response.placement_state
}))
"""
    output = run(
        ["mise", "exec", "--", "mix", "run", "--no-start", "-e", expression],
        cwd=repo,
        env=env,
        timeout=130,
    )
    evidence = tagged_json(output, "KAP112_LOGICAL_LOAD_JSON=", "logical load")
    if (
        evidence.get("failure_code") not in {"", None}
        or evidence.get("loaded") is not True
        or evidence.get("model") != MODEL
    ):
        raise ProofFailure("Node Runtime did not confirm the exact logical model load")
    return evidence


def wait_for_live(process: subprocess.Popen[bytes], timeout: int = 120) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ProofFailure("Orchard exited before liveness")
        try:
            response = urllib.request.urlopen("http://127.0.0.1:4000/health/live", timeout=1)
            if response.status == 200:
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.5)
    raise ProofFailure("Orchard did not become live")


def stop_process_group(process: subprocess.Popen[Any]) -> None:
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    except PermissionError:
        pass
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            process.wait()
            return
        except PermissionError:
            pass
        time.sleep(0.05)
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        process.wait()
        return
    except PermissionError:
        pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            process.wait()
            return
        except PermissionError:
            pass
        time.sleep(0.05)
    raise ProofFailure("owned process group termination could not be confirmed after SIGKILL")


def preflight(args: argparse.Namespace, manifest: dict[str, Any]) -> tuple[str, str, Path]:
    head, tree = git_identity(args.repo)
    if head != args.accepted_commit or tree != args.accepted_tree:
        raise ProofFailure(
            "source commit/tree does not match the separately accepted Gate-2 identity"
        )
    verify_manifest_identity(args.repo, args.manifest, head)
    verify_snapshot_manifest(args.repo, manifest["identity"])
    parent = run(["git", "rev-parse", f"{head}^"], cwd=args.repo)
    if parent != manifest["identity"]["source_parent"]:
        raise ProofFailure("runner source ancestry drifted from the accepted adapter/setup commit")
    opencode = verify_opencode(manifest["identity"]["opencode"])
    for port, name in REQUIRED_PORTS.items():
        require_clear_port(port, name)
    if args.prepare_only:
        require_clear_port(PROVIDER_PORT, "vLLM")
        require_clear_port(POSTGRES_PORT, "PostgreSQL")
    else:
        require_loopback_listener(PROVIDER_PORT, "vLLM")
        require_loopback_listener(POSTGRES_PORT, "PostgreSQL")
    if not args.proof_root.is_dir() or stat.S_IMODE(args.proof_root.stat().st_mode) != 0o700:
        raise ProofFailure("proof root must already exist with owner-only mode 0700")
    for path in (args.bundle_dir, args.token_file):
        if args.proof_root not in path.parents:
            raise ProofFailure("bundle and token paths must remain under the proof root")
    if not args.bundle_dir.is_dir() or args.token_file.exists():
        raise ProofFailure("proof bundle is absent or token path already exists")
    if path_entry_exists(args.proof_root / "runner-state"):
        raise ProofFailure("KAP-112 runner state already exists")
    if path_entry_exists(args.proof_root / "artifacts"):
        raise ProofFailure("KAP-112 runner artifact state already exists")
    if not args.prepare_only and (
        path_entry_exists(stage_receipt_path(args.proof_root))
        or path_entry_exists(
            stage_receipt_path(args.proof_root).with_name(STAGE_RECEIPT_FILENAME + ".tmp")
        )
    ):
        raise ProofFailure("KAP-112 stage receipt state already exists")
    require_worker_socket_path_budget(args.proof_root / "runner-state")
    return head, tree, opencode


def prepare_calibration(
    args: argparse.Namespace,
    manifest: dict[str, Any],
    head: str,
    tree: str,
    opencode: Path,
    work_root: Path,
    env: dict[str, str],
) -> dict[str, Any]:
    calibration_path = args.proof_root / "kap112-calibration.json"
    if calibration_path.exists():
        raise ProofFailure("KAP-112 calibration receipt already exists")
    units, long_path = calibrate_long_context(
        opencode,
        repo=args.repo,
        work_root=work_root,
        bundle=args.bundle_dir,
        spec=manifest["long_context"],
        base_env=env,
        config_home=work_root / "opencode-config",
    )
    receipt = {
        "schema_version": 1,
        "source": {"commit": head, "tree": tree},
        "manifest_sha256": sha256(args.manifest),
        "opencode_sha256": manifest["identity"]["opencode"]["sha256"],
        "opencode_dependencies_sha256": manifest["identity"]["opencode_dependencies"]["sha256"],
        "tokenizer_assets_sha256": tokenizer_asset_hashes(args.bundle_dir),
        "model": manifest["identity"]["model"],
        "generator": manifest["long_context"]["generator"],
        "padding_units": units,
        "long_sha256": sha256(long_path),
        "input_tokens": manifest["identity"]["input_tokens"],
        "overflow_input_tokens": manifest["overflow"]["input_tokens"],
        "provider_or_gpu_used": False,
    }
    calibration_path.write_bytes(json_bytes(receipt) + b"\n")
    calibration_path.chmod(0o600)
    return receipt


def load_calibrated_context(
    args: argparse.Namespace,
    manifest: dict[str, Any],
    head: str,
    tree: str,
    work_root: Path,
    opencode: Path,
    env: dict[str, str],
) -> tuple[int, Path, Path]:
    path = args.proof_root / "kap112-calibration.json"
    try:
        receipt = json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise ProofFailure("KAP-112 offline calibration receipt is absent or invalid") from None
    expected = {
        "schema_version": 1,
        "source": {"commit": head, "tree": tree},
        "manifest_sha256": sha256(args.manifest),
        "opencode_sha256": manifest["identity"]["opencode"]["sha256"],
        "opencode_dependencies_sha256": manifest["identity"]["opencode_dependencies"]["sha256"],
        "tokenizer_assets_sha256": tokenizer_asset_hashes(args.bundle_dir),
        "model": manifest["identity"]["model"],
        "generator": manifest["long_context"]["generator"],
        "input_tokens": manifest["identity"]["input_tokens"],
        "overflow_input_tokens": manifest["overflow"]["input_tokens"],
        "provider_or_gpu_used": False,
    }
    if not isinstance(receipt, dict) or any(
        receipt.get(key) != value for key, value in expected.items()
    ):
        raise ProofFailure("KAP-112 offline calibration identity drifted")
    units = receipt.get("padding_units")
    if not isinstance(units, int) or isinstance(units, bool) or units < 1:
        raise ProofFailure("KAP-112 offline calibration padding is invalid")
    long_path = work_root / "long-context.txt"
    long_path.write_text(long_context_text(manifest["long_context"], units))
    if sha256(long_path) != receipt.get("long_sha256"):
        raise ProofFailure("KAP-112 calibrated long-context fixture drifted")
    long_request = capture_opencode_request(
        opencode,
        root=work_root / "live-recount-long",
        repository=work_root,
        message=long_context_message(manifest["long_context"], long_path.read_text()),
        base_env=env,
        config_home=work_root / "opencode-config",
    )
    if count_captured_request(args.repo, args.bundle_dir, long_request) != 131_072:
        raise ProofFailure("live long-context reconstruction did not recount to 131072")
    overflow_path = work_root / "overflow-context.txt"
    overflow_path.write_text(overflow_context_text(manifest["long_context"], units))
    overflow_request = capture_opencode_request(
        opencode,
        root=work_root / "live-recount-overflow",
        repository=work_root,
        message=long_context_message(manifest["long_context"], overflow_path.read_text()),
        base_env=env,
        config_home=work_root / "opencode-config",
    )
    if count_captured_request(args.repo, args.bundle_dir, overflow_request) != 131_073:
        raise ProofFailure("live overflow reconstruction did not recount to 131073")
    return units, long_path, overflow_path


def setup_fixture_command(bundle_dir: Path, token_file: Path) -> list[str]:
    return [
        "mise",
        "exec",
        "--",
        "mix",
        "run",
        "scripts/kap112_setup_fixture.exs",
        str(bundle_dir),
        str(token_file),
    ]


def start_orchard(repo: Path, env: dict[str, str], orchard_log: Any) -> subprocess.Popen[bytes]:
    launch_env = env | {
        "ORCHARD_REQUEST_TIMEOUT_MS": "360000",
        "ORCHARD_MAX_REQUEST_DEADLINE_MS": "360000",
    }
    return subprocess.Popen(
        ["mise", "exec", "--", "bin/dev"],
        cwd=repo,
        env=launch_env,
        stdin=subprocess.PIPE,
        stdout=orchard_log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )


def stop_orchard(process: subprocess.Popen[bytes]) -> None:
    try:
        stop_process_group(process)
    finally:
        if process.stdin is not None:
            process.stdin.close()


def execute(args: argparse.Namespace, manifest: dict[str, Any]) -> dict[str, Any]:
    raise ProofFailure(
        "historical KAP-112 live proof is disabled: current-main rendered effort "
        "uses legacy_blended, not the final_only registration in this fixture"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the exact source-only KAP-112 proof unit")
    parser.add_argument("--accepted-commit", required=True)
    parser.add_argument("--accepted-tree", required=True)
    parser.add_argument("--proof-root", type=Path, required=True)
    parser.add_argument("--bundle-dir", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).parent / "fixtures" / "kap112" / "manifest.json",
    )
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    return parser.parse_args(argv)


def cleanup_runner_state(args: argparse.Namespace, *, remove_artifacts: bool) -> None:
    cleanup_paths = [args.proof_root / "runner-state"]
    if remove_artifacts:
        cleanup_paths.append(args.proof_root / "artifacts")
    try:
        args.token_file.unlink(missing_ok=True)
        stage_receipt_path(args.proof_root).with_name(STAGE_RECEIPT_FILENAME + ".tmp").unlink(
            missing_ok=True
        )
        for path in cleanup_paths:
            try:
                shutil.rmtree(path, ignore_errors=False)
            except FileNotFoundError:
                pass
    except OSError as error:
        raise ProofFailure("unable to remove KAP-112 runner-owned temporary state") from error
    if path_entry_exists(args.token_file) or any(path_entry_exists(path) for path in cleanup_paths):
        raise ProofFailure("KAP-112 runner-owned temporary state remains")


def interrupt_proof(signum: int, _frame: Any) -> None:
    raise ProofFailure(f"KAP-112 runner interrupted by signal {signum}")


def main(argv: list[str] | None = None) -> int:
    parse_args(sys.argv[1:] if argv is None else argv)
    print(
        "error: historical KAP-112 live proof is disabled pending current-main "
        "rendered-effort fixture reconciliation",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
