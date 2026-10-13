from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_PATH = REPO_ROOT / "scripts" / "kap112_smoke_runner.py"
MANIFEST_PATH = REPO_ROOT / "scripts" / "fixtures" / "kap112" / "manifest.json"


def _runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("kap112_smoke_runner", RUNNER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_frozen_manifest_and_context_recipe_are_deterministic() -> None:
    runner = _runner()
    manifest = runner.load_manifest(MANIFEST_PATH)
    runner.verify_snapshot_manifest(REPO_ROOT, manifest["identity"])

    first = runner.long_context_text(manifest["long_context"], 20)
    second = runner.long_context_text(manifest["long_context"], 20)
    overflow = runner.overflow_context_text(manifest["long_context"], 20)

    assert first == second
    assert first.count(manifest["long_context"]["padding_atom"]) == 20
    assert overflow == runner.long_context_text(manifest["long_context"], 21)
    assert overflow.count(manifest["long_context"]["padding_atom"]) == 21
    assert overflow != first + manifest["long_context"]["padding_atom"]
    positions = [
        first.index(marker)
        for marker in (
            "KAP112_START=alder",
            "KAP112_QUARTER=birch",
            "KAP112_THREE_QUARTER=cedar",
            "KAP112_END=dogwood",
        )
    ]
    assert positions == sorted(positions)
    assert first.index("EARLIER_INSTRUCTION") < first.index("LATER_INSTRUCTION")
    assert manifest["identity"]["input_tokens"] == 131_072
    assert manifest["overflow"]["input_tokens"] == 131_073
    assert manifest["direct_api"]["request"]["max_output_tokens"] == 128
    assert manifest["direct_api"]["request"]["temperature"] == 1.0
    assert manifest["direct_api"]["request"]["top_p"] == 0.95
    assert manifest["direct_api"]["request"]["reasoning"] == {"effort": "medium"}


def test_short_fixture_is_frozen_and_baseline_fails(tmp_path: Path) -> None:
    runner = _runner()
    manifest = runner.load_manifest(MANIFEST_PATH)
    fixture = tmp_path / "fixture"

    hashes = runner.materialize_short_fixture(manifest["short_opencode"], fixture)

    assert hashes == manifest["short_opencode"]["initial_sha256"]
    result = runner.command_result(
        manifest["short_opencode"]["baseline_command"], cwd=fixture, timeout=10
    )
    assert result.returncode != 0
    assert "assert 3 == 11" in result.stdout


def test_short_fixture_outcome_rejects_extra_paths_and_wrong_content(tmp_path: Path) -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["short_opencode"]
    fixture = tmp_path / "fixture"
    runner.materialize_short_fixture(spec, fixture)
    (fixture / "calculator.py").write_text(
        "def add(left: int, right: int) -> int:\n    return left + right\n"
    )

    assert (
        runner.validate_short_fixture_outcome(fixture, spec, spec["initial_sha256"])
        == spec["expected_patch_sha256"]
    )
    unexpected = fixture / "notes.txt"
    unexpected.write_text("not part of the frozen outcome")
    with pytest.raises(runner.ProofFailure, match="file set drifted"):
        runner.verify_short_fixture_outcome(fixture, spec)
    unexpected.unlink()
    unexpected.mkdir()
    with pytest.raises(runner.ProofFailure, match="directory set drifted"):
        runner.verify_short_fixture_outcome(fixture, spec)
    unexpected.rmdir()
    unexpected.symlink_to(fixture / "calculator.py")
    with pytest.raises(runner.ProofFailure, match="unexpected path type"):
        runner.verify_short_fixture_outcome(fixture, spec)
    unexpected.unlink()
    (fixture / "calculator.py").write_text(
        "def add(left: int, right: int) -> int:\n    return left + right + 0\n"
    )
    with pytest.raises(runner.ProofFailure, match="outcome drifted"):
        runner.verify_short_fixture_outcome(fixture, spec)


def test_opencode_config_disables_external_and_automatic_behavior(tmp_path: Path) -> None:
    runner = _runner()
    token_file = tmp_path / "token"
    token_file.write_text("not-a-live-secret")
    config_path = tmp_path / "opencode.json"

    runner.write_opencode_config(config_path, token_file)
    config = json.loads(config_path.read_text())

    assert config["share"] == "disabled"
    assert config["autoupdate"] is False
    assert config["compaction"] == {"auto": False, "prune": False, "reserved": 8192}
    assert config["provider"]["openai"]["options"]["baseURL"] == "http://127.0.0.1:4000/v1"
    assert config["provider"]["openai"]["options"]["setCacheKey"] is False
    assert "permission" not in config
    assert config["disabled_providers"]


def test_opencode_tool_schema_translation_is_exact_and_fail_closed() -> None:
    runner = _runner()
    flattened = {
        "type": "function",
        "name": "read",
        "description": "Read a fixture",
        "parameters": {"type": "object"},
        "strict": False,
    }

    payload, translated = runner.normalize_opencode_tool_schema({"tools": [flattened]})

    assert translated is True
    assert payload["tools"] == [
        {
            "type": "function",
            "function": {
                "name": "read",
                "description": "Read a fixture",
                "parameters": {"type": "object"},
                "strict": False,
            },
        }
    ]
    with pytest.raises(runner.ProofFailure, match="schema drifted"):
        runner.normalize_opencode_tool_schema({"tools": [flattened | {"unexpected": "value"}]})
    with pytest.raises(runner.ProofFailure, match="schema drifted"):
        runner.normalize_opencode_tool_schema(
            {"tools": [{key: value for key, value in flattened.items() if key != "strict"}]}
        )

    assert runner.normalize_opencode_sampling({"model": "fixture"}) == {
        "model": "fixture",
        "temperature": 1.0,
        "top_p": 0.95,
        "reasoning": {"effort": "medium"},
        "max_output_tokens": 8192,
    }
    with pytest.raises(runner.ProofFailure, match="sampling schema drifted"):
        runner.normalize_opencode_sampling({"temperature": 0})
    with pytest.raises(runner.ProofFailure, match="sampling schema drifted"):
        runner.normalize_opencode_sampling({"reasoning": {"effort": "medium"}})
    with pytest.raises(runner.ProofFailure, match="sampling schema drifted"):
        runner.normalize_opencode_sampling({"max_output_tokens": 8192})


def test_opencode_tool_stream_expansion_is_exact_and_fail_closed() -> None:
    runner = _runner()
    first_call = {
        "type": "function_call",
        "id": "call_0",
        "call_id": "call_0",
        "name": "read",
        "arguments": '{"path":"README.md"}',
        "status": "completed",
    }
    second_call = first_call | {
        "id": "call_1",
        "call_id": "call_1",
        "name": "grep",
        "arguments": '{"pattern":"fixture"}',
    }
    message = {
        "type": "message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": "done", "annotations": []}],
    }
    created = {
        "type": "response.created",
        "response": {"id": "resp_0", "status": "in_progress"},
    }
    delta = {
        "type": "response.output_text.delta",
        "response_id": "resp_0",
        "output_index": 0,
        "content_index": 0,
        "delta": "done",
    }
    text_done = {
        "type": "response.output_text.done",
        "response_id": "resp_0",
        "output_index": 0,
        "content_index": 0,
        "text": "done",
    }
    terminal = {
        "type": "response.completed",
        "response": {
            "id": "resp_0",
            "output": [message, first_call, second_call],
            "output_text": "done",
            "status": "completed",
        },
    }

    def body_for(*events: dict[str, object], terminated: bool = True) -> bytes:
        body = "\n\n".join(
            f"event: {event['type']}\ndata: {json.dumps(event, separators=(',', ':'))}"
            for event in events
        )
        return (body + ("\n\n" if terminated else "")).encode()

    body = body_for(created, delta, text_done, terminal)

    expanded, expanded_calls, status_override = runner.expand_opencode_tool_stream(
        body, "text/event-stream"
    )
    blocks = expanded.decode().strip().split("\n\n")

    assert status_override is None
    assert expanded_calls == [
        {
            "call_id": "resp_0-kap112-call-1",
            "name": "read",
            "arguments": {"path": "README.md"},
        },
        {
            "call_id": "resp_0-kap112-call-2",
            "name": "grep",
            "arguments": {"pattern": "fixture"},
        },
    ]
    assert [block.splitlines()[0] for block in blocks] == [
        "event: response.created",
        "event: response.output_item.added",
        "event: response.output_text.delta",
        "event: response.output_item.done",
        "event: response.output_item.added",
        "event: response.output_item.done",
        "event: response.output_item.added",
        "event: response.output_item.done",
        "event: response.completed",
    ]
    text_delta = json.loads(blocks[2].split("data: ", 1)[1])
    first_added = json.loads(blocks[4].split("data: ", 1)[1])
    second_done = json.loads(blocks[7].split("data: ", 1)[1])
    assert text_delta["item_id"] == "resp_0-kap112-message-0"
    assert first_added["output_index"] == 1
    assert first_added["item"] == {
        **{
            key: value
            for key, value in first_call.items()
            if key not in {"status", "id", "call_id"}
        },
        "id": "resp_0-kap112-call-1",
        "call_id": "resp_0-kap112-call-1",
    }
    assert second_done["output_index"] == 2
    assert second_done["item"] == second_call | {
        "id": "resp_0-kap112-call-2",
        "call_id": "resp_0-kap112-call-2",
    }

    with pytest.raises(runner.ProofFailure, match="function call schema drifted"):
        runner.expand_opencode_tool_stream(
            body_for(
                created,
                delta,
                text_done,
                terminal
                | {
                    "response": terminal["response"]
                    | {"output": [message, first_call, second_call | {"id": "call_0"}]}
                },
            ),
            "text/event-stream",
        )
    with pytest.raises(runner.ProofFailure, match="event sequence drifted"):
        runner.expand_opencode_tool_stream(
            body_for(created, {"type": "response.output_item.added"}, terminal),
            "text/event-stream",
        )
    with pytest.raises(runner.ProofFailure, match="terminal response schema drifted"):
        runner.expand_opencode_tool_stream(
            body_for(created, terminal | {"response": terminal["response"] | {"status": "failed"}}),
            "text/event-stream",
        )
    with pytest.raises(runner.ProofFailure, match="was not terminated"):
        runner.expand_opencode_tool_stream(
            body_for(created, delta, text_done, terminal, terminated=False),
            "text/event-stream",
        )
    for malformed in (
        body_for(created, text_done, delta, terminal),
        body_for(created, delta, text_done, delta, terminal),
    ):
        with pytest.raises(runner.ProofFailure, match="message schema drifted"):
            runner.expand_opencode_tool_stream(malformed, "text/event-stream")


def test_opencode_tool_history_translation_is_correlated_and_fail_closed() -> None:
    runner = _runner()
    call_id = "resp_0-kap112-call-1"
    second_call_id = "resp_0-kap112-call-2"
    expected = {
        call_id: {"name": "read", "arguments": {"path": "README.md"}},
        second_call_id: {"name": "wait", "arguments": {"milliseconds": 60_000.0}},
    }
    payload = {
        "input": [
            {"role": "user", "content": "inspect"},
            {
                "type": "function_call",
                "call_id": call_id,
                "name": "read",
                "arguments": '{"path":"README.md"}',
            },
            {
                "type": "function_call",
                "call_id": second_call_id,
                "name": "wait",
                "arguments": '{"milliseconds":60000}',
            },
            {"type": "function_call_output", "call_id": call_id, "output": "fixture"},
            {"type": "function_call_output", "call_id": second_call_id, "output": "done"},
        ]
    }

    normalized, call_ids = runner.normalize_opencode_tool_history(payload, expected)

    assert call_ids == {call_id, second_call_id}
    assert normalized["input"] == [
        {"role": "user", "content": "inspect"},
        {
            "role": "assistant",
            "content": (
                "<tool_call>\n<function=read>\n<parameter=path>\nREADME.md\n"
                "</parameter>\n</function>\n</tool_call>\n"
                "<tool_call>\n<function=wait>\n<parameter=milliseconds>\n60000\n"
                "</parameter>\n</function>\n</tool_call>"
            ),
        },
        {
            "role": "user",
            "content": (
                "<tool_response>\nfixture\n</tool_response>\n"
                "<tool_response>\ndone\n</tool_response>"
            ),
        },
    ]
    with pytest.raises(runner.ProofFailure, match="history schema drifted"):
        runner.normalize_opencode_tool_history(
            payload
            | {
                "input": [
                    payload["input"][0],
                    payload["input"][1] | {"name": "write"},
                    payload["input"][2],
                    *payload["input"][3:],
                ]
            },
            expected,
        )
    missing_result = payload | {"input": payload["input"][:-1]}
    with pytest.raises(runner.ProofFailure, match="result set drifted"):
        runner.normalize_opencode_tool_history(missing_result, expected)
    replayed, replayed_ids = runner.normalize_opencode_tool_history(payload, expected)
    assert replayed == normalized
    assert replayed_ids == call_ids
    changed_value = payload | {
        "input": [
            *payload["input"][:2],
            payload["input"][2] | {"arguments": '{"milliseconds":60001}'},
            *payload["input"][3:],
        ]
    }
    with pytest.raises(runner.ProofFailure, match="history schema drifted"):
        runner.normalize_opencode_tool_history(changed_value, expected)
    assert runner.json_values_equal(True, 1) is False
    with pytest.raises(runner.ProofFailure, match="function name drifted"):
        runner.qwen_tool_call_text("read>", {"path": "README.md"})
    with pytest.raises(runner.ProofFailure, match="argument name drifted"):
        runner.qwen_tool_call_text("read", {"": "README.md"})
    assert runner.qwen_tool_call_text(
        "inspect", {"options": {"text": "</parameter>&'", "values": [2, 1]}}
    ) == (
        "<tool_call>\n<function=inspect>\n<parameter=options>\n"
        '{"text": "\\u003c/parameter\\u003e\\u0026\\u0027", "values": [2, 1]}\n'
        "</parameter>\n</function>\n</tool_call>"
    )

    mixed_payload = payload | {
        "input": [
            payload["input"][0],
            {
                "type": "message",
                "role": "assistant",
                "content": [
                    {
                        "type": "output_text",
                        "text": "I’ll inspect both files.",
                        "annotations": [],
                    }
                ],
            },
            *payload["input"][1:],
        ]
    }
    mixed, mixed_ids = runner.normalize_opencode_tool_history(mixed_payload, expected)
    assert mixed_ids == call_ids
    assert mixed["input"] == [
        {"role": "user", "content": "inspect"},
        {
            "role": "assistant",
            "content": (
                "I’ll inspect both files.\n\n"
                "<tool_call>\n<function=read>\n<parameter=path>\nREADME.md\n"
                "</parameter>\n</function>\n</tool_call>\n"
                "<tool_call>\n<function=wait>\n<parameter=milliseconds>\n60000\n"
                "</parameter>\n</function>\n</tool_call>"
            ),
        },
        normalized["input"][-1],
    ]
    without_annotations = json.loads(json.dumps(mixed_payload))
    del without_annotations["input"][1]["content"][0]["annotations"]
    normalized_without_annotations, call_ids_without_annotations = (
        runner.normalize_opencode_tool_history(without_annotations, expected)
    )
    assert call_ids_without_annotations == call_ids
    assert normalized_without_annotations == mixed
    for accepted_part in (
        {"type": "output_text", "text": "preserved"},
        {"type": "output_text", "text": "preserved", "annotations": []},
    ):
        standalone, standalone_call_ids = runner.normalize_opencode_tool_history(
            {"input": [{"role": "assistant", "content": [accepted_part]}]},
            {},
        )
        assert standalone_call_ids == set()
        assert standalone["input"] == [
            {
                "role": "assistant",
                "content": [{"type": "input_text", "text": "preserved"}],
            }
        ]
    for rejected_part in (
        {"type": "output_text", "text": "x", "extra": "unsafe"},
        {"type": "output_text", "text": "x", "annotations": [], "extra": "unsafe"},
        {"type": "output_text", "text": "x", "annotations": None},
        {"type": "output_text", "text": "x", "annotations": False},
        {"type": "output_text", "text": "x", "annotations": {}},
        {"type": "output_text", "text": "x", "annotations": ""},
    ):
        with pytest.raises(runner.ProofFailure, match="assistant history content drifted"):
            runner.normalize_opencode_tool_history(
                {"input": [{"role": "assistant", "content": [rejected_part]}]},
                {},
            )
    with pytest.raises(runner.ProofFailure, match="assistant history content drifted"):
        runner.normalize_opencode_tool_history(
            mixed_payload
            | {
                "input": [
                    mixed_payload["input"][0],
                    mixed_payload["input"][1]
                    | {
                        "content": [
                            {
                                "type": "output_text",
                                "text": "unsafe annotation",
                                "annotations": [{"type": "unknown"}],
                            }
                        ]
                    },
                    *mixed_payload["input"][2:],
                ]
            },
            expected,
        )
    for malformed_message in (
        mixed_payload["input"][1] | {"type": "reasoning"},
        mixed_payload["input"][1] | {"summary": [{"text": "discarded"}]},
        {"role": [], "content": "x"},
        {"role": {}, "content": "x"},
        {"role": "user", "content": [{"type": [], "text": "x"}]},
        {"role": "user", "content": [{"type": {}, "text": "x"}]},
    ):
        with pytest.raises(runner.ProofFailure, match="message .* drifted"):
            runner.normalize_opencode_tool_history(
                mixed_payload
                | {
                    "input": [
                        mixed_payload["input"][0],
                        malformed_message,
                        *mixed_payload["input"][2:],
                    ]
                },
                expected,
            )

    server = runner.OrchardProxyServer()
    try:
        server.register_tool_calls(
            [
                {"call_id": call_id, **expected[call_id]},
                {"call_id": second_call_id, **expected[second_call_id]},
            ]
        )
        server.register_forwarded_tool_results({call_id})
        synthesized, forwarded = server.tool_result_identity_snapshot()
        assert synthesized == {call_id, second_call_id}
        assert forwarded == {call_id}
        server.register_forwarded_tool_results({call_id})
        assert server.tool_result_identity_snapshot()[1] == {call_id}
    finally:
        server.server_close()


def test_opencode_proxy_rejects_route_method_and_framing_drift_before_orchard() -> None:
    runner = _runner()
    server = runner.OrchardProxyServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    try:
        request = urllib.request.Request(base_url + "/wrong", data=b"{}")
        with pytest.raises(urllib.error.HTTPError) as wrong_route:
            urllib.request.urlopen(request)
        assert wrong_route.value.code == 400
        assert server.request_snapshot()[-1]["failure_detail"] == "OpenCode request path drifted"

        with pytest.raises(urllib.error.HTTPError) as wrong_method:
            urllib.request.urlopen(base_url + "/v1/responses")
        assert wrong_method.value.code == 405

        with socket.create_connection(("127.0.0.1", server.server_port)) as connection:
            connection.sendall(
                b"POST /v1/responses HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Content-Length: sentinel-secret\r\n\r\n"
            )
            response = connection.recv(4096)
        assert b"400" in response
        assert b"sentinel-secret" not in response

        with socket.create_connection(("127.0.0.1", server.server_port)) as connection:
            connection.sendall(
                b"POST /v1/responses HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Content-Length: "
                + str(runner.OPENCODE_REQUEST_MAX_BYTES + 1).encode()
                + b"\r\n\r\n"
            )
            oversized = connection.recv(4096)
        assert b"400" in oversized

        for request_line in (
            b"TRACE-sentinel /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            b"malformed-sentinel-request-line\r\n\r\n",
        ):
            with socket.create_connection(("127.0.0.1", server.server_port)) as connection:
                connection.sendall(request_line)
                response = connection.recv(4096)
            assert b"sentinel" not in response
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    requests = server.request_snapshot()
    assert [request["state"] for request in requests] == [
        "rejected",
        "rejected",
        "rejected",
        "rejected",
        "rejected",
        "rejected",
    ]
    assert [request["status"] for request in requests] == [400, 405, 400, 400, 501, 400]
    assert runner.OrchardProxyServer.daemon_threads is False
    assert runner.OrchardProxyServer.block_on_close is True


def test_setup_fixture_command_passes_exact_script_arguments(tmp_path: Path) -> None:
    runner = _runner()
    bundle = tmp_path / "bundle"
    token = tmp_path / "token"

    assert runner.setup_fixture_command(bundle, token) == [
        "mise",
        "exec",
        "--",
        "mix",
        "run",
        "scripts/kap112_setup_fixture.exs",
        str(bundle),
        str(token),
    ]


def test_orchard_launch_keeps_iex_stdin_open(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    observed: dict[str, object] = {}
    sentinel = object()

    def popen(command: list[str], **options: object) -> object:
        observed["command"] = command
        observed.update(options)
        return sentinel

    monkeypatch.setattr(runner.subprocess, "Popen", popen)
    with (tmp_path / "orchard.log").open("wb") as orchard_log:
        process = runner.start_orchard(tmp_path, {"MIX_ENV": "dev"}, orchard_log)

    assert process is sentinel
    assert observed["command"] == ["mise", "exec", "--", "bin/dev"]
    assert observed["env"] == {
        "MIX_ENV": "dev",
        "ORCHARD_REQUEST_TIMEOUT_MS": "360000",
        "ORCHARD_MAX_REQUEST_DEADLINE_MS": "360000",
    }
    assert observed["stdin"] == subprocess.PIPE
    assert observed["start_new_session"] is True


def test_orchard_stop_closes_stdin_after_failed_group_shutdown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    runner = _runner()
    events: list[str] = []

    class Stdin:
        def close(self) -> None:
            events.append("close")

    process = type("Process", (), {"stdin": Stdin()})()

    def fail_stop(_process: object) -> None:
        events.append("stop")
        raise runner.ProofFailure("shutdown failed")

    monkeypatch.setattr(runner, "stop_process_group", fail_stop)

    with pytest.raises(runner.ProofFailure, match="shutdown failed"):
        runner.stop_orchard(process)

    assert events == ["stop", "close"]


def test_direct_response_validation_requires_exact_identity_usage_and_text() -> None:
    runner = _runner()
    valid = {
        "id": "resp_fixture",
        "object": "response",
        "status": "completed",
        "model": runner.MODEL,
        "output_text": "ORCHARD_KAP112_DIRECT_OK",
        "usage": {"input_tokens": 9, "output_tokens": 4, "total_tokens": 13},
    }

    assert runner.validate_response(valid, "ORCHARD_KAP112_DIRECT_OK")["request_id"] == (
        "resp_fixture"
    )
    invalid = valid | {"model": "other"}
    with pytest.raises(runner.ProofFailure, match="model identity drifted"):
        runner.validate_response(invalid, "ORCHARD_KAP112_DIRECT_OK")


def test_long_event_validation_distinguishes_exact_boundary() -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["long_context"]
    answer = {
        "anchors": ["alder", "birch", "cedar", "dogwood"],
        "instruction": "answer-new",
        "dependency_result": 43,
        "tool_nonce": "9f4a312671b7489c",
    }
    events = [
        {"type": "step_start", "part": {}},
        {"type": "text", "part": {"text": json.dumps(answer, separators=(",", ":"))}},
        {
            "type": "step_finish",
            "part": {
                "reason": "stop",
                "tokens": {"input": 131_072, "output": 20, "total": 131_092},
            },
        },
    ]
    raw = "\n".join(json.dumps(event) for event in events)

    summary = runner.validate_long_events(raw, spec, 131_072)
    assert summary["observed_input_tokens"] == [131_072]
    assert summary["terminal_answer"] == answer

    with pytest.raises(runner.ProofFailure, match="exactly 131073"):
        runner.validate_long_events(raw, spec, 131_073)

    echoed = events.copy()
    echoed[1] = {"type": "text", "part": {"text": "the prompt mentioned alder and dogwood"}}
    with pytest.raises(runner.ProofFailure, match="exact JSON"):
        runner.validate_long_events("\n".join(json.dumps(event) for event in echoed), spec, 131_072)

    wrong = answer | {"dependency_result": 42, "tool_nonce": "unknown-sensitive-value"}
    wrong_events = events.copy()
    wrong_events[1] = {
        "type": "text",
        "part": {"text": json.dumps(wrong, separators=(",", ":"))},
    }
    with pytest.raises(runner.ProofFailure, match='"integer":42') as error:
        runner.validate_long_events(
            "\n".join(json.dumps(event) for event in wrong_events), spec, 131_072
        )
    assert "unknown-sensitive-value" not in str(error.value)
    assert hashlib.sha256(json.dumps(wrong["tool_nonce"]).encode()).hexdigest() in str(error.value)

    for non_object in ([], "sensitive", 7, True, None):
        non_object_events = events.copy()
        non_object_events[1] = {
            "type": "text",
            "part": {"text": json.dumps(non_object)},
        }
        with pytest.raises(runner.ProofFailure, match="was not an object") as error:
            runner.validate_long_events(
                "\n".join(json.dumps(event) for event in non_object_events), spec, 131_072
            )
        assert "sensitive" not in str(error.value)


def test_opencode_attempt_observation_precedes_semantic_validation(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    proxy = runner.OrchardProxyServer()
    try:
        runner.persist_stage_receipt(proof_root, "long_context", "started")
        first = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(first, state="translated", status=200)
        raw = "\n".join(
            [
                json.dumps({"type": "step_start", "part": {}}),
                json.dumps({"type": "text", "part": {"text": "{}"}}),
                json.dumps(
                    {
                        "type": "step_finish",
                        "part": {"reason": "stop", "tokens": {"input": 7}},
                    }
                ),
            ]
        )

        assert runner.persist_opencode_attempts_before_validation(
            proof_root, "long_context", proxy, 0, raw
        ) == (1, 1)
        assert (
            runner.load_stage_receipts(runner.stage_receipt_path(proof_root))[-1]["status"]
            == "observed"
        )
        spec = runner.load_manifest(MANIFEST_PATH)["long_context"]
        with pytest.raises(runner.ProofFailure, match="exactly 131072"):
            runner.validate_long_events(raw, spec, 131_072)
    finally:
        proxy.server_close()


def test_opencode_attempt_observation_precedes_answer_validation_and_retry(
    tmp_path: Path,
) -> None:
    runner = _runner()
    answer_mismatch = "\n".join(
        [
            json.dumps({"type": "step_start", "part": {}}),
            json.dumps({"type": "text", "part": {"text": "{}"}}),
            json.dumps(
                {
                    "type": "step_finish",
                    "part": {"reason": "stop", "tokens": {"input": 131_072}},
                }
            ),
        ]
    )
    spec = runner.load_manifest(MANIFEST_PATH)["long_context"]

    proof_root = tmp_path / "answer"
    proof_root.mkdir(mode=0o700)
    proxy = runner.OrchardProxyServer()
    try:
        runner.persist_stage_receipt(proof_root, "long_context", "started")
        first = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(first, state="translated", status=200)
        assert runner.persist_opencode_attempts_before_validation(
            proof_root, "long_context", proxy, 0, answer_mismatch
        ) == (1, 1)
        with pytest.raises(runner.ProofFailure, match="answer drifted"):
            runner.validate_long_events(answer_mismatch, spec, 131_072)
    finally:
        proxy.server_close()

    proof_root = tmp_path / "retry"
    proof_root.mkdir(mode=0o700)
    proxy = runner.OrchardProxyServer()
    try:
        runner.persist_stage_receipt(proof_root, "long_context", "started")
        first = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(first, state="translated", status=200)
        second = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(second, state="translated", status=200)
        with pytest.raises(runner.ProofFailure, match="automatic API retry"):
            runner.persist_opencode_attempts_before_validation(
                proof_root, "long_context", proxy, 0, answer_mismatch
            )
        assert (
            runner.load_stage_receipts(runner.stage_receipt_path(proof_root))[-1]["evidence"][
                "api_requests"
            ]
            == 2
        )
    finally:
        proxy.server_close()


def test_padding_calibration_finds_exact_boundary_and_rejects_gaps() -> None:
    runner = _runner()

    assert runner.find_padding_units(lambda units: units + 100, target=131_072) == 130_972
    with pytest.raises(runner.ProofFailure, match="cannot produce exactly"):
        runner.find_padding_units(lambda units: units * 2, target=131_071)


def test_offline_capture_uses_only_loopback_fixture(tmp_path: Path) -> None:
    runner = _runner()
    fake = tmp_path / "fake-opencode"
    fake.write_text(
        """#!/usr/bin/env python3
import json, os, sys, urllib.error, urllib.request
config = json.load(open(os.environ["OPENCODE_CONFIG"]))
url = config["provider"]["openai"]["options"]["baseURL"] + "/responses"
body = json.dumps({
    "model": "fixture",
    "input": [{"role": "user", "content": sys.stdin.read()}],
    "tools": [{
        "type": "function",
        "name": "read",
        "description": "Read a fixture",
        "parameters": {"type": "object"},
        "strict": False,
    }],
})
headers = {"content-type": "application/json"}
request = urllib.request.Request(url, data=body.encode(), headers=headers)
try:
    urllib.request.urlopen(request)
except urllib.error.HTTPError:
    pass
"""
    )
    fake.chmod(0o700)
    root = tmp_path / "capture"
    root.mkdir()
    repository = tmp_path / "repo"
    repository.mkdir()
    attachment = repository / "context.txt"
    attachment.write_text("fixture")

    payload = runner.capture_opencode_request(
        fake,
        root=root,
        repository=repository,
        message="fixture from stdin",
        base_env=os.environ.copy(),
    )

    assert payload["input"] == [{"role": "user", "content": "fixture from stdin"}]

    fake.write_text(
        fake.read_text().replace(
            '    "model": "fixture",',
            '    "prompt_cache_key": "unexpected",\n    "model": "fixture",',
        )
    )
    with pytest.raises(runner.ProofFailure, match="prompt cache key remained enabled"):
        runner.capture_opencode_request(
            fake,
            root=tmp_path / "capture-with-cache-key",
            repository=repository,
            message="fixture from stdin",
            base_env=os.environ.copy(),
        )


def test_offline_capture_bounds_stalled_stdin_delivery(tmp_path: Path) -> None:
    runner = _runner()
    fake = tmp_path / "stalled-opencode"
    fake.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
    fake.chmod(0o700)
    repository = tmp_path / "repo"
    repository.mkdir()

    started = time.monotonic()
    with pytest.raises(runner.ProofFailure, match="timed out"):
        runner.capture_opencode_request(
            fake,
            root=tmp_path / "capture",
            repository=repository,
            message="x" * 262_144,
            base_env=os.environ.copy(),
            timeout=0.2,
        )
    assert time.monotonic() - started < 2


def test_calibration_reuses_adjacent_binary_search_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["long_context"]
    calls: list[int] = []
    monkeypatch.setattr(runner, "long_context_text", lambda _spec, units: f"units={units}")
    monkeypatch.setattr(runner, "long_context_message", lambda _spec, context: context)

    def fake_capture(*_args: object, **options: object) -> dict[str, int]:
        units = int(str(options["message"]).removeprefix("units="))
        calls.append(units)
        return {"units": units}

    monkeypatch.setattr(runner, "capture_opencode_request", fake_capture)
    monkeypatch.setattr(
        runner,
        "count_captured_request",
        lambda _repo, _bundle, request: request["units"] + 5_509,
    )
    work_root = tmp_path / "work"
    work_root.mkdir()

    units, long_path = runner.calibrate_long_context(
        tmp_path / "opencode",
        repo=tmp_path,
        work_root=work_root,
        bundle=tmp_path / "bundle",
        spec=spec,
        base_env={},
        config_home=tmp_path / "config",
    )

    assert units == 125_563
    assert calls.count(125_564) == 1
    assert long_path.read_text() == "units=125563"


def test_live_recount_reconstructs_the_calibrated_overflow_recipe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    manifest = runner.load_manifest(MANIFEST_PATH)
    spec = manifest["long_context"]
    units = 20
    proof_root = tmp_path / "proof"
    bundle = proof_root / "bundle"
    work_root = proof_root / "work"
    bundle.mkdir(parents=True)
    work_root.mkdir()
    for name in runner.TOKENIZER_ASSETS:
        (bundle / name).write_text(name)
    long_path = tmp_path / "long.txt"
    long_path.write_text(runner.long_context_text(spec, units))
    head = "a" * 40
    tree = "b" * 40
    receipt = {
        "schema_version": 1,
        "source": {"commit": head, "tree": tree},
        "manifest_sha256": runner.sha256(MANIFEST_PATH),
        "opencode_sha256": manifest["identity"]["opencode"]["sha256"],
        "opencode_dependencies_sha256": manifest["identity"]["opencode_dependencies"]["sha256"],
        "tokenizer_assets_sha256": runner.tokenizer_asset_hashes(bundle),
        "model": manifest["identity"]["model"],
        "generator": spec["generator"],
        "padding_units": units,
        "long_sha256": runner.sha256(long_path),
        "input_tokens": manifest["identity"]["input_tokens"],
        "overflow_input_tokens": manifest["overflow"]["input_tokens"],
        "provider_or_gpu_used": False,
    }
    (proof_root / "kap112-calibration.json").write_text(json.dumps(receipt))
    captured_messages: list[str] = []

    def capture(*_args: object, **options: object) -> dict[str, int]:
        captured_messages.append(str(options["message"]))
        return {"sequence": len(captured_messages)}

    monkeypatch.setattr(runner, "capture_opencode_request", capture)
    monkeypatch.setattr(
        runner,
        "count_captured_request",
        lambda _repo, _bundle, request: 131_071 + request["sequence"],
    )
    args = SimpleNamespace(
        proof_root=proof_root,
        manifest=MANIFEST_PATH,
        bundle_dir=bundle,
        repo=REPO_ROOT,
    )

    _, reconstructed_long, reconstructed_overflow = runner.load_calibrated_context(
        args, manifest, head, tree, work_root, tmp_path / "opencode", {}
    )

    expected_overflow = runner.overflow_context_text(spec, units)
    assert reconstructed_long.read_text() == long_path.read_text()
    assert reconstructed_overflow.read_text() == expected_overflow
    assert expected_overflow != long_path.read_text() + spec["padding_atom"]
    assert captured_messages[1] == runner.long_context_message(spec, expected_overflow)


@pytest.mark.parametrize(
    ("counts", "message"),
    [
        ([131_071], "live long-context reconstruction"),
        ([131_072, 131_072], "live overflow reconstruction"),
    ],
)
def test_live_recount_fails_closed_on_wrong_boundary(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    counts: list[int],
    message: str,
) -> None:
    runner = _runner()
    manifest = runner.load_manifest(MANIFEST_PATH)
    spec = manifest["long_context"]
    proof_root = tmp_path / "proof"
    bundle = proof_root / "bundle"
    work_root = proof_root / "work"
    bundle.mkdir(parents=True)
    work_root.mkdir()
    for name in runner.TOKENIZER_ASSETS:
        (bundle / name).write_text(name)
    long_path = tmp_path / "long.txt"
    long_path.write_text(runner.long_context_text(spec, 20))
    head = "a" * 40
    tree = "b" * 40
    receipt = {
        "schema_version": 1,
        "source": {"commit": head, "tree": tree},
        "manifest_sha256": runner.sha256(MANIFEST_PATH),
        "opencode_sha256": manifest["identity"]["opencode"]["sha256"],
        "opencode_dependencies_sha256": manifest["identity"]["opencode_dependencies"]["sha256"],
        "tokenizer_assets_sha256": runner.tokenizer_asset_hashes(bundle),
        "model": manifest["identity"]["model"],
        "generator": spec["generator"],
        "padding_units": 20,
        "long_sha256": runner.sha256(long_path),
        "input_tokens": manifest["identity"]["input_tokens"],
        "overflow_input_tokens": manifest["overflow"]["input_tokens"],
        "provider_or_gpu_used": False,
    }
    (proof_root / "kap112-calibration.json").write_text(json.dumps(receipt))
    remaining = iter(counts)
    monkeypatch.setattr(runner, "capture_opencode_request", lambda *_args, **_options: {})
    monkeypatch.setattr(
        runner, "count_captured_request", lambda _repo, _bundle, _request: next(remaining)
    )
    args = SimpleNamespace(
        proof_root=proof_root,
        manifest=MANIFEST_PATH,
        bundle_dir=bundle,
        repo=REPO_ROOT,
    )

    with pytest.raises(runner.ProofFailure, match=message):
        runner.load_calibrated_context(
            args, manifest, head, tree, work_root, tmp_path / "opencode", {}
        )


def test_short_events_prove_open_client_tool_use_without_policing_surface() -> None:
    runner = _runner()
    events = [
        {"type": "step_start", "part": {}},
        {
            "type": "tool_use",
            "part": {
                "tool": "bash",
                "state": {
                    "status": "completed",
                    "input": {"command": "python -m pytest -q"},
                    "output": "1 passed",
                    "metadata": {"exit": 0},
                },
            },
        },
        {
            "type": "tool_use",
            "part": {
                "tool": "future-client-tool",
                "state": {
                    "status": "completed",
                    "input": {"value": "client-owned"},
                },
            },
        },
        {"type": "text", "part": {"text": "Fixed calculator.py"}},
        {"type": "step_finish", "part": {"reason": "stop", "tokens": {"input": 20}}},
    ]
    raw = "\n".join(json.dumps(event) for event in events)

    summary = runner.validate_short_events(raw, 20, 20)

    assert summary["completed_tool_event_count"] == 2
    assert summary["finish_tokens"] == [{"input": 20}]
    with pytest.raises(
        runner.ProofFailure,
        match=(
            r"count=2 maximum=1 observed=.*finish_reason='stop' "
            r"finish_tokens=\[\{'input': 20\}\].*text_length=19 "
            r".*text_tail='Fixed \[REDACTED\]'"
        ),
    ):
        runner.validate_short_events(raw, 20, 1, secrets=("calculator.py",))
    without_tools = [events[0], *events[3:]]
    with pytest.raises(runner.ProofFailure, match="tool-event bound"):
        runner.validate_short_events(
            "\n".join(json.dumps(event) for event in without_tools), 20, 20
        )
    with pytest.raises(runner.ProofFailure, match="terminal summary"):
        empty_summary = [*events[:3], {"type": "text", "part": {"text": "  "}}, events[4]]
        runner.validate_short_events(
            "\n".join(json.dumps(event) for event in empty_summary), 20, 20
        )


def test_short_client_proof_runs_installed_opencode_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["short_opencode"]
    observed: list[tuple[list[str], dict[str, Any]]] = []

    def fake_run_opencode(command: list[str], **options: Any) -> subprocess.CompletedProcess[str]:
        observed.append((command, options))
        return subprocess.CompletedProcess(command, 0, "client-events", "")

    monkeypatch.setattr(runner, "run_opencode", fake_run_opencode)

    assert (
        runner.run_short_opencode(
            opencode=tmp_path / "opencode",
            repository=tmp_path,
            environment={"PATH": "/bin"},
            spec=spec,
            token="fixture",
        )
        == "client-events"
    )

    command, options = observed[0]
    assert len(observed) == 1
    assert command[0] == str(tmp_path / "opencode")
    assert "--pure" not in command
    assert command[-1] == spec["prompt"]
    assert options == {
        "cwd": tmp_path,
        "env": {"PATH": "/bin"},
        "timeout": spec["wall_timeout_seconds"],
    }


def test_short_client_proof_reports_process_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    monkeypatch.setattr(
        runner,
        "run_opencode",
        lambda *_args, **_options: subprocess.CompletedProcess([], 7, "", "failed"),
    )

    with pytest.raises(runner.ProofFailure, match="API-client proof exited"):
        runner.run_short_opencode(
            opencode=tmp_path / "opencode",
            repository=tmp_path,
            environment={},
            spec=runner.load_manifest(MANIFEST_PATH)["short_opencode"],
            token="fixture",
        )


def test_overflow_requires_one_typed_refusal_without_generation() -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["overflow"]
    provider_error = {
        "error": {
            "type": "invalid_request_error",
            "code": "context_length_exceeded",
            "message": "too long",
        }
    }
    error_event = {
        "type": "error",
        "error": {
            "name": "ContextOverflowError",
            "data": {"responseBody": json.dumps(provider_error)},
        },
    }
    raw = "\n".join(json.dumps(error_event) for _index in range(2))

    assert runner.validate_overflow_events(raw, spec)["duplicate_event_count"] == 2

    for invalid_type in ("missing", None, "server_error"):
        invalid_type_event = json.loads(json.dumps(error_event))
        provider_body = json.loads(invalid_type_event["error"]["data"]["responseBody"])
        if invalid_type == "missing":
            provider_body["error"].pop("type")
        else:
            provider_body["error"]["type"] = invalid_type
        invalid_type_event["error"]["data"]["responseBody"] = json.dumps(provider_body)
        with pytest.raises(runner.ProofFailure, match="type or code drifted"):
            runner.validate_overflow_events(json.dumps(invalid_type_event), spec)

    response_id = "resp_overflow"
    failed_events = [
        {
            "type": "response.created",
            "response": {"id": response_id, "status": "in_progress"},
        },
        {
            "type": "response.failed",
            "response": {
                "id": response_id,
                "status": "failed",
                "output": [],
                "output_text": "",
                "error": provider_error["error"],
            },
        },
    ]
    failed_stream = (
        "\n\n".join(
            f"event: {event['type']}\ndata: {json.dumps(event, separators=(',', ':'))}"
            for event in failed_events
        )
        + "\n\n"
    ).encode()
    normalized_failure, calls, status_override = runner.expand_opencode_tool_stream(
        failed_stream, "text/event-stream"
    )
    assert json.loads(normalized_failure) == provider_error
    assert calls == []
    assert status_override == 400

    for created_change, failed_change in (
        ({"id": None}, {}),
        ({"id": ""}, {"id": ""}),
        ({"id": 7}, {"id": 7}),
        ({"output": [{"type": "message"}]}, {}),
        ({"output_text": "generated"}, {}),
        ({}, {"output_text": []}),
        ({}, {"output_text": {}}),
    ):
        malformed_events = json.loads(json.dumps(failed_events))
        malformed_events[0]["response"].update(created_change)
        malformed_events[1]["response"].update(failed_change)
        malformed_stream = (
            "\n\n".join(
                f"event: {event['type']}\ndata: {json.dumps(event, separators=(',', ':'))}"
                for event in malformed_events
            )
            + "\n\n"
        ).encode()
        with pytest.raises(runner.ProofFailure, match="failed response stream schema drifted"):
            runner.expand_opencode_tool_stream(malformed_stream, "text/event-stream")

    with pytest.raises(runner.ProofFailure, match="advanced"):
        runner.validate_overflow_events(
            raw + "\n" + json.dumps({"type": "text", "part": {"text": "echo"}}), spec
        )

    malformed_body = json.loads(json.dumps(error_event))
    malformed_body["error"]["data"]["responseBody"] = "sensitive non-json body"
    with pytest.raises(runner.ProofFailure, match='"parsed":false') as error:
        runner.validate_overflow_events(json.dumps(malformed_body), spec)
    assert "sensitive non-json body" not in str(error.value)

    missing_error = json.loads(json.dumps(error_event))
    missing_error["error"]["data"]["responseBody"] = json.dumps({"detail": "sensitive"})
    with pytest.raises(runner.ProofFailure, match=r'"response_keys":\["detail"\]') as error:
        runner.validate_overflow_events(json.dumps(missing_error), spec)
    assert "sensitive" not in str(error.value)


def test_overflow_proxy_requires_exact_single_http_refusal() -> None:
    runner = _runner()
    spec = runner.load_manifest(MANIFEST_PATH)["overflow"]
    evidence = {
        "method": "POST",
        "path": "/v1/responses",
        "state": "translated",
        "status": 400,
        "error_type": "invalid_request_error",
        "error_code": "context_length_exceeded",
        "tool_history_translations": 0,
        "tool_stream_expansions": 0,
    }

    assert runner.validate_overflow_proxy_evidence([evidence], spec) == evidence
    without_duplicate_error_fields = evidence | {"error_type": None, "error_code": None}
    assert (
        runner.validate_overflow_proxy_evidence([without_duplicate_error_fields], spec)
        == without_duplicate_error_fields
    )
    with pytest.raises(runner.ProofFailure, match="HTTP refusal"):
        runner.validate_overflow_proxy_evidence([evidence | {"status": 200}], spec)
    with pytest.raises(runner.ProofFailure, match="HTTP refusal"):
        runner.validate_overflow_proxy_evidence([evidence | {"tool_stream_expansions": 1}], spec)
    with pytest.raises(runner.ProofFailure, match="HTTP refusal"):
        runner.validate_overflow_proxy_evidence([evidence | {"error_type": "server_error"}], spec)


def test_bounded_environment_removes_credentials_and_external_proxies() -> None:
    runner = _runner()
    bounded = runner.bounded_environment(
        {
            "PATH": "/bin",
            "PGHOST": "127.0.0.1",
            "MISE_DATA_DIR": "/mise",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "HF_TOKEN": "secret",
            "HTTPS_PROXY": "http://external.invalid",
        }
    )

    assert bounded == {
        "PATH": "/bin",
        "PGHOST": "127.0.0.1",
        "MISE_DATA_DIR": "/mise",
    }


def test_opencode_environment_uses_disposable_state_without_restricting_client(
    tmp_path: Path,
) -> None:
    runner = _runner()
    environment = runner.opencode_proof_env(
        tmp_path / "identity",
        tmp_path / "opencode.json",
        {
            "HOME": "/home/developer",
            "PATH": "/bin",
            "PGPASSWORD": "secret",
            "MISE_DATA_DIR": "/mise",
        },
    )

    assert environment["HOME"] == "/home/developer"
    assert environment["PATH"] == "/bin"
    assert environment["MISE_DATA_DIR"] == "/mise"
    assert "PGPASSWORD" not in environment
    assert environment["XDG_DATA_HOME"].startswith(str(tmp_path))
    assert environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1"
    assert environment["OPENCODE_DISABLE_SHARE"] == "1"
    assert not any(
        key in environment
        for key in (
            "OPENCODE_DISABLE_DEFAULT_PLUGINS",
            "OPENCODE_DISABLE_EXTERNAL_SKILLS",
            "OPENCODE_DISABLE_LSP_DOWNLOAD",
            "OPENCODE_DISABLE_PROJECT_CONFIG",
        )
    )


def test_opencode_dependency_seed_is_identity_bound_and_copied(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    source = tmp_path / "source"
    plugin = source / "node_modules" / "@opencode-ai" / "plugin"
    plugin.mkdir(parents=True)
    (source / "package.json").write_text("{}")
    (source / "package-lock.json").write_text("{}")
    (plugin / "package.json").write_text(json.dumps({"version": "1.18.30"}))
    digest, size, count = runner.opencode_dependency_identity(source)
    identity = {
        "path": "${ORCHARD_KAP112_SNAPSHOT_ROOT}/source",
        "plugin_version": "1.18.30",
        "sha256": digest,
        "size_bytes": size,
        "file_count": count,
    }
    destination = tmp_path / "destination"

    monkeypatch.delenv("ORCHARD_KAP112_SNAPSHOT_ROOT", raising=False)
    with pytest.raises(runner.ProofFailure, match="incomplete"):
        runner.prepare_opencode_dependencies(identity, destination)
    monkeypatch.setenv("ORCHARD_KAP112_SNAPSHOT_ROOT", str(tmp_path))
    runner.prepare_opencode_dependencies(identity, destination)

    assert runner.opencode_dependency_identity(destination) == (digest, size, count)

    binary = tmp_path / "opencode"
    binary.write_bytes(b"synthetic OpenCode binary")
    binary_identity = {
        "path": "${ORCHARD_KAP112_SNAPSHOT_ROOT}/opencode",
        "sha256": hashlib.sha256(b"synthetic OpenCode binary").hexdigest(),
        "size_bytes": len(b"synthetic OpenCode binary"),
    }
    assert runner.verify_opencode(binary_identity) == binary
    monkeypatch.delenv("ORCHARD_KAP112_SNAPSHOT_ROOT")
    with pytest.raises(runner.ProofFailure, match="missing"):
        runner.verify_opencode(binary_identity)


def test_manifest_must_be_canonical_and_bound_to_accepted_tree(tmp_path: Path) -> None:
    runner = _runner()
    repository = tmp_path / "repo"
    manifest = repository / "scripts" / "fixtures" / "kap112" / "manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('{"schema_version":1}\n')
    subprocess.run(["git", "init", "--quiet", repository], check=True)
    subprocess.run(["git", "-C", repository, "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            repository,
            "-c",
            "user.name=KAP-112 test",
            "-c",
            "user.email=kap112@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "fixture",
        ],
        check=True,
    )
    head = subprocess.check_output(
        ["git", "-C", repository, "rev-parse", "HEAD"], text=True
    ).strip()

    runner.verify_manifest_identity(repository, manifest.resolve(), head)
    with pytest.raises(runner.ProofFailure, match="canonical"):
        runner.verify_manifest_identity(repository, tmp_path / "external.json", head)
    manifest.write_text('{"schema_version":2}\n')
    with pytest.raises(runner.ProofFailure, match="accepted source tree"):
        runner.verify_manifest_identity(repository, manifest.resolve(), head)


def test_tokenizer_count_is_offline_and_credential_stripped(tmp_path: Path) -> None:
    runner = _runner()
    observed: dict[str, object] = {}
    (tmp_path / "tokenizer.json").write_text("{}")
    (tmp_path / "tokenizer_config.json").write_text("{}")
    (tmp_path / "chat_template.jinja").write_text("fixture")
    (tmp_path / "reasoning_contract_template.json").write_text(
        json.dumps(
            {
                "chat_template_digest": hashlib.sha256(b"fixture").hexdigest(),
                "render_contract": "kap112-qwen3.8-medium",
                "render_contract_version": "1",
                "parser_family": "prompt_opened",
                "parser_version": "v1",
                "runtime_contract_version": "vllm-poc-v1",
                "event_binding_version": "worker-runtime-v1",
            }
        )
    )

    def fake_run(command: list[str], **options: object) -> str:
        observed["command"] = command
        observed["environment"] = options["env"]
        observed["input_text"] = options["input_text"]
        request = json.loads(options["input_text"])
        return json.dumps(
            {
                "result": {
                    "input_token_count": 42,
                    "reasoning": request["request"]["reasoning"],
                }
            }
        )

    runner.run = fake_run
    os.environ["HF_TOKEN"] = "must-not-pass"
    try:
        assert (
            runner.count_captured_request(
                tmp_path,
                tmp_path,
                {
                    "instructions": "system",
                    "input": [
                        {
                            "role": "user",
                            "content": [{"type": "input_text", "text": "fixture"}],
                        }
                    ],
                },
            )
            == 42
        )
    finally:
        os.environ.pop("HF_TOKEN")

    assert "--offline" in observed["command"]
    assert "--frozen" in observed["command"]
    assert observed["environment"]["UV_OFFLINE"] == "1"
    assert "HF_TOKEN" not in observed["environment"]
    assert "--request-json" not in observed["command"]
    request = json.loads(observed["input_text"])["request"]
    assert request["reasoning"]["reasoning_effort"] == "medium"
    assert request["input_items"] == [
        {"role": "system", "content": "system"},
        {"role": "user", "content": [{"type": "text", "text": "fixture"}]},
    ]


def test_tokenizer_count_rejects_unsupported_responses_content(tmp_path: Path) -> None:
    runner = _runner()

    with pytest.raises(runner.ProofFailure, match="content part is unsupported"):
        runner.count_captured_request(
            tmp_path,
            tmp_path,
            {
                "input": [
                    {
                        "role": "user",
                        "content": [{"type": "input_image", "image_url": "file:///tmp/x"}],
                    }
                ]
            },
        )


def test_normalizes_observed_opencode_attachment_capture() -> None:
    runner = _runner()

    assert runner.normalize_responses_input(
        {
            "input": [
                {"role": "system", "content": "OpenCode system prompt"},
                {
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "Called the Read tool"},
                        {"type": "input_text", "text": "<content>fixture</content>"},
                        {"type": "input_text", "text": "Return exact JSON"},
                    ],
                },
            ]
        }
    ) == [
        {"role": "system", "content": "OpenCode system prompt"},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "Called the Read tool"},
                {"type": "text", "text": "<content>fixture</content>"},
                {"type": "text", "text": "Return exact JSON"},
            ],
        },
    ]


def test_opencode_timeout_terminates_owned_process_group(tmp_path: Path) -> None:
    runner = _runner()
    child_pid_path = tmp_path / "child.pid"
    program = tmp_path / "spawn.py"
    program.write_text(
        """import subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
open(sys.argv[1], "w").write(str(child.pid))
"""
    )

    with pytest.raises(runner.ProofFailure, match="exceeded"):
        runner.run_opencode(
            [sys.executable, str(program), str(child_pid_path)],
            cwd=tmp_path,
            env=os.environ.copy(),
            timeout=0.2,
        )

    child_pid = int(child_pid_path.read_text())
    deadline = time.monotonic() + 2
    while Path(f"/proc/{child_pid}").exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not Path(f"/proc/{child_pid}").exists()


def test_logical_unload_requires_acknowledged_unloaded_status(tmp_path: Path) -> None:
    runner = _runner()

    def fake_run(command: list[str], **_kwargs: object) -> str:
        assert "Application.ensure_all_started(:grpc)" in command[-1]
        return "startup log\nKAP112_LOGICAL_UNLOAD_JSON=" + json.dumps(
            {"ack": True, "message": "unload accepted", "still_loaded": False}
        )

    runner.run = fake_run

    evidence = runner.logical_unload(tmp_path, {})

    assert evidence["ack"] is True
    assert evidence["still_loaded"] is False


def test_logical_load_requires_exact_loaded_model_evidence(tmp_path: Path) -> None:
    runner = _runner()

    def fake_run(command: list[str], **_kwargs: object) -> str:
        expression = command[-1]
        assert "artifact_source_uri: model.artifact_uri" in expression
        assert "Path.expand(model.artifact_uri)" not in expression
        assert 'artifact_uri.scheme != "file"' in expression
        assert "Application.ensure_all_started(:grpc)" in expression
        assert "node_id = before_status.node_metadata.node_id" in expression
        assert "node_id: before_status.node_id" not in expression
        return "startup log\nKAP112_LOGICAL_LOAD_JSON=" + json.dumps(
            {
                "already_loaded": False,
                "failure_code": "",
                "loaded": True,
                "model": runner.MODEL,
                "placement_state": "PLACEMENT_STATE_LOADED",
            }
        )

    runner.run = fake_run

    evidence = runner.logical_load(tmp_path, {})

    assert evidence["loaded"] is True
    assert evidence["model"] == runner.MODEL


def test_tagged_json_rejects_duplicate_receipts() -> None:
    runner = _runner()
    output = 'RECEIPT={"ok":true}\nRECEIPT={"ok":true}\n'

    with pytest.raises(runner.ProofFailure, match="exactly one tagged JSON receipt"):
        runner.tagged_json(output, "RECEIPT=", "operation")


def test_durable_request_count_accepts_tag_amid_ecto_logs(tmp_path: Path) -> None:
    runner = _runner()

    def fake_run(command: list[str], **_kwargs: object) -> str:
        assert 'IO.puts("KAP112_REQUEST_COUNT=" <> Integer.to_string(count))' in command[-1]
        return (
            "14:27:13.201 [debug] QUERY OK db=2.0ms\n"
            "select count(*) from requests []\n"
            "KAP112_REQUEST_COUNT=7"
        )

    runner.run = fake_run

    assert runner.durable_request_count(tmp_path, {}) == 7


@pytest.mark.parametrize(
    "output,message",
    [
        ("debug only", "exactly one"),
        ("KAP112_REQUEST_COUNT=1\nKAP112_REQUEST_COUNT=1", "exactly one"),
        ("KAP112_REQUEST_COUNT=-1", "invalid"),
        ("KAP112_REQUEST_COUNT=1 extra", "invalid"),
        ("KAP112_REQUEST_COUNT=١", "invalid"),
    ],
)
def test_tagged_integer_fails_closed(output: str, message: str) -> None:
    runner = _runner()

    with pytest.raises(runner.ProofFailure, match=message):
        runner.tagged_nonnegative_integer(output, "KAP112_REQUEST_COUNT=", "counter")


def test_stage_receipts_are_atomic_ordered_and_owner_only(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)

    runner.persist_stage_receipt(proof_root, "direct_api", "started")
    runner.persist_stage_receipt(
        proof_root,
        "direct_api",
        "completed",
        {
            "elapsed_ms": 12,
            "model": runner.MODEL,
            "request_id_sha256": "a" * 64,
            "usage": {"input_tokens": 3, "output_tokens": 2},
            "console_rendered": True,
            "scheduler_selected": True,
        },
    )

    path = runner.stage_receipt_path(proof_root)
    receipts = runner.load_stage_receipts(path)
    assert [receipt["ordinal"] for receipt in receipts] == [1, 2]
    assert receipts[-1]["evidence"]["elapsed_ms"] == 12
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert not path.with_name(path.name + ".tmp").exists()
    assert runner.active_receipt_stage(proof_root) == "runner"


def test_stage_failure_receipt_persists_only_typed_hash_evidence(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    runner.persist_stage_receipt(proof_root, "overflow", "started")
    error = "sensitive output must not persist"

    runner.persist_stage_receipt(
        proof_root,
        runner.active_receipt_stage(proof_root),
        "failed",
        {
            "error_type": "ProofFailure",
            "error_length": len(error),
            "error_sha256": hashlib.sha256(error.encode()).hexdigest(),
        },
    )

    path = runner.stage_receipt_path(proof_root)
    assert error not in path.read_text()
    assert runner.load_stage_receipts(path)[-1] == {
        "ordinal": 2,
        "stage": "overflow",
        "status": "failed",
        "evidence": {
            "error_type": "ProofFailure",
            "error_length": len(error),
            "error_sha256": hashlib.sha256(error.encode()).hexdigest(),
        },
    }


def test_request_observation_precedes_retry_invariant_and_is_content_redacted(
    tmp_path: Path,
) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    proxy = runner.OrchardProxyServer()
    try:
        runner.persist_stage_receipt(proof_root, "short_opencode", "started")
        first = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(
            first,
            state="translated",
            status=503,
            error_type="server_error",
            error_code="busy",
            failure="sensitive failure detail with spaces",
        )
        second = proxy.begin_request("POST", "/v1/responses")
        proxy.update_request(second, state="translated", status=200)

        request_count = runner.persist_request_observation(
            proof_root, "short_opencode", proxy, 0, 1
        )

        assert request_count == 2
        receipts = runner.load_stage_receipts(runner.stage_receipt_path(proof_root))
        assert receipts[-1]["status"] == "observed"
        evidence = receipts[-1]["evidence"]
        assert evidence["api_requests"] == 2
        assert evidence["model_turn_count"] == 1
        assert evidence["api_attempts"][0] == {
            "ordinal": 1,
            "method": "POST",
            "path": "/v1/responses",
            "state": "translated",
            "status": 503,
            "error_type": "sha256:" + hashlib.sha256(b"server_error").hexdigest(),
            "error_code": "sha256:" + hashlib.sha256(b"busy").hexdigest(),
            "failure": "sha256:"
            + hashlib.sha256(b"sensitive failure detail with spaces").hexdigest(),
            "failure_detail_length": 0,
            "failure_detail_sha256": "",
            "failure_evidence_sha256": runner.failure_evidence_sha256(
                "sha256:" + hashlib.sha256(b"sensitive failure detail with spaces").hexdigest(),
                0,
                "",
            ),
            "response_event_types": [],
            "response_sequence_observed": False,
            "response_status": "",
            "response_error_type": "",
            "response_error_code": "",
            "response_error_message_length": 0,
            "response_error_message_sha256": "",
        }
        assert "sensitive failure detail" not in runner.stage_receipt_path(proof_root).read_text()
        assert runner.active_receipt_stage(proof_root) == "short_opencode"

        runner.persist_stage_receipt(
            proof_root,
            "short_opencode",
            "failed",
            {
                "error_type": "ProofFailure",
                "error_length": 5,
                "error_sha256": "a" * 64,
            },
        )
    finally:
        proxy.server_close()


def test_request_attempt_redacts_safe_tokens_and_sensitive_paths() -> None:
    runner = _runner()

    evidence = runner.typed_request_attempt(
        {
            "method": "GET",
            "path": "/snapshot-root/private/credential",
            "state": "secretstate",
            "status": 500,
            "error_type": "supersecret",
            "error_code": "secret_code",
            "failure": "/snapshot-root/private/failure",
        },
        1,
    )

    assert evidence["ordinal"] == 1
    assert evidence["status"] == 500
    for field in ("method", "path", "state", "error_type", "error_code", "failure"):
        assert evidence[field].startswith("sha256:")
    assert "secret" not in json.dumps(evidence)
    assert "/snapshot-root" not in json.dumps(evidence)


def test_stage_receipt_rejects_plaintext_attempt_error_evidence(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    runner.persist_stage_receipt(proof_root, "short_opencode", "started")

    with pytest.raises(runner.ProofFailure, match="evidence is not typed"):
        runner.persist_stage_receipt(
            proof_root,
            "short_opencode",
            "observed",
            {
                "api_attempts": [
                    {
                        "ordinal": 1,
                        "method": "POST",
                        "path": "/v1/responses",
                        "state": "translated",
                        "status": 500,
                        "error_type": "plaintext_secret",
                        "error_code": "",
                        "failure": "",
                        "failure_detail_length": 0,
                        "failure_detail_sha256": "",
                        "failure_evidence_sha256": "",
                        "response_event_types": [],
                        "response_sequence_observed": False,
                        "response_status": "",
                        "response_error_type": "",
                        "response_error_code": "",
                        "response_error_message_length": 0,
                        "response_error_message_sha256": "",
                    }
                ],
                "api_requests": 1,
                "model_turn_count": 1,
            },
        )


def test_request_attempt_hashes_stream_failure_detail_without_content() -> None:
    runner = _runner()
    detail = "OpenCode terminal function call schema drifted"

    evidence = runner.typed_request_attempt(
        {
            "method": "POST",
            "path": "/v1/responses",
            "state": "rejected",
            "status": 502,
            "failure": "response_stream_drift",
            "failure_detail": detail,
        },
        1,
    )

    assert evidence["failure_detail_length"] == len(detail)
    assert (
        evidence["failure_detail_sha256"] == "sha256:" + hashlib.sha256(detail.encode()).hexdigest()
    )
    assert detail not in json.dumps(evidence)

    for field, replacement in (
        ("failure_detail_length", len(detail) + 1),
        ("failure_detail_sha256", "sha256:" + "0" * 64),
    ):
        forged = evidence | {field: replacement}
        assert runner.valid_api_attempts([forged]) is False


def test_request_attempt_preserves_typed_sequence_without_error_content() -> None:
    runner = _runner()
    detail = {
        "event_types": ["response.created", "response.failed"],
        "status": "failed",
        "error_type": "sensitive_error",
        "error_code": "sensitive_code",
        "error_message_length": len("sensitive parser detail"),
        "error_message_sha256": hashlib.sha256(b"sensitive parser detail").hexdigest(),
    }

    evidence = runner.typed_request_attempt(
        {
            "method": "POST",
            "path": "/v1/responses",
            "state": "rejected",
            "status": 502,
            "failure": "response_stream_drift",
            "failure_detail": str(runner.ResponseSequenceDrift(detail)),
            "response_sequence": detail,
        },
        1,
    )

    assert evidence["response_sequence_observed"] is True
    assert evidence["response_event_types"] == ["response.created", "response.failed"]
    assert evidence["response_status"] == "failed"
    assert (
        evidence["response_error_type"]
        == "sha256:" + hashlib.sha256(b"sensitive_error").hexdigest()
    )
    assert (
        evidence["response_error_code"] == "sha256:" + hashlib.sha256(b"sensitive_code").hexdigest()
    )
    assert evidence["response_error_message_length"] == len("sensitive parser detail")
    assert evidence["response_error_message_sha256"] == (
        "sha256:" + hashlib.sha256(b"sensitive parser detail").hexdigest()
    )
    assert "sensitive" not in json.dumps(evidence)
    assert runner.valid_api_attempts([evidence]) is True

    for field, replacement in (
        ("response_error_message_length", evidence["response_error_message_length"] + 1),
        ("response_error_message_sha256", "sha256:" + "0" * 64),
    ):
        assert runner.valid_api_attempts([evidence | {field: replacement}]) is False


def test_response_sequence_drift_never_renders_plaintext_error_message(tmp_path: Path) -> None:
    runner = _runner()
    secret = "generated-sensitive-parser-detail"
    events = [
        {"type": "response.created", "response": {"id": "resp_fixture"}},
        {
            "type": "response.output_text.delta",
            "response_id": "resp_fixture",
            "output_index": 0,
            "content_index": 0,
            "delta": "generated",
        },
        {
            "type": "response.failed",
            "response": {
                "id": "resp_fixture",
                "status": "failed",
                "error": {
                    "type": "server_error",
                    "code": "tool_call_parse_failed",
                    "message": secret,
                },
            },
        },
    ]
    body = (
        "\n\n".join(
            f"event: {event['type']}\ndata: {json.dumps(event, separators=(',', ':'))}"
            for event in events
        )
        + "\n\n"
    ).encode()

    with pytest.raises(runner.ResponseSequenceDrift) as exc_info:
        runner.expand_opencode_tool_stream(body, "text/event-stream")

    error = exc_info.value
    rendered = str(error)
    attempt = runner.typed_request_attempt(
        {
            "method": "POST",
            "path": "/v1/responses",
            "state": "rejected",
            "status": 502,
            "failure": "response_stream_drift",
            "failure_detail": rendered,
            "response_sequence": error.evidence,
        },
        1,
    )
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    runner.persist_stage_receipt(proof_root, "short_opencode", "started")
    runner.persist_stage_receipt(
        proof_root,
        "short_opencode",
        "observed",
        {"api_attempts": [attempt], "api_requests": 1, "model_turn_count": 1},
    )
    persisted = runner.stage_receipt_path(proof_root).read_text()

    expected_hash = hashlib.sha256(secret.encode()).hexdigest()
    assert secret not in rendered
    assert secret not in persisted
    assert error.evidence == {
        "event_types": [
            "response.created",
            "response.output_text.delta",
            "response.failed",
        ],
        "status": "failed",
        "error_type": "server_error",
        "error_code": "tool_call_parse_failed",
        "error_message_length": len(secret),
        "error_message_sha256": expected_hash,
    }
    assert expected_hash in persisted


def test_request_attempt_preserves_empty_response_sequence_drift() -> None:
    runner = _runner()
    detail = {"event_types": [], "status": None, "error_type": None, "error_code": None}
    error = runner.ResponseSequenceDrift(detail)

    evidence = runner.typed_request_attempt(
        {
            "method": "POST",
            "path": "/v1/responses",
            "state": "rejected",
            "status": 502,
            "failure": "response_stream_drift",
            "failure_detail": str(error),
            "response_sequence": error.evidence,
        },
        1,
    )

    assert evidence["response_sequence_observed"] is True
    assert evidence["response_event_types"] == []
    assert runner.valid_api_attempts([evidence]) is True


@pytest.mark.parametrize(
    "failure,detail_length,detail_sha256",
    [
        (
            "sha256:" + hashlib.sha256(b"other").hexdigest(),
            8,
            "sha256:" + hashlib.sha256(b"detail-x").hexdigest(),
        ),
        ("", 8, "sha256:" + hashlib.sha256(b"detail-x").hexdigest()),
        ("sha256:" + hashlib.sha256(b"response_stream_drift").hexdigest(), 0, ""),
    ],
)
def test_stage_receipt_rejects_incoherent_attempt_failure_evidence(
    tmp_path: Path,
    failure: str,
    detail_length: int,
    detail_sha256: str,
) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    runner.persist_stage_receipt(proof_root, "short_opencode", "started")
    failure_evidence = runner.failure_evidence_sha256(failure, detail_length, detail_sha256)

    with pytest.raises(runner.ProofFailure, match="evidence is not typed"):
        runner.persist_stage_receipt(
            proof_root,
            "short_opencode",
            "observed",
            {
                "api_attempts": [
                    {
                        "ordinal": 1,
                        "method": "POST",
                        "path": "/v1/responses",
                        "state": "rejected",
                        "status": 502,
                        "error_type": "",
                        "error_code": "",
                        "failure": failure,
                        "failure_detail_length": detail_length,
                        "failure_detail_sha256": detail_sha256,
                        "failure_evidence_sha256": failure_evidence,
                        "response_event_types": [],
                        "response_sequence_observed": False,
                        "response_status": "",
                        "response_error_type": "",
                        "response_error_code": "",
                        "response_error_message_length": 0,
                        "response_error_message_sha256": "",
                    }
                ],
                "api_requests": 1,
                "model_turn_count": 1,
            },
        )


def test_stage_receipt_rejects_temporary_path_collision(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)
    temporary = runner.stage_receipt_path(proof_root).with_name(
        runner.STAGE_RECEIPT_FILENAME + ".tmp"
    )
    temporary.write_text("collision")

    with pytest.raises(runner.ProofFailure, match="temporary path collided"):
        runner.persist_stage_receipt(proof_root, "direct_api", "started")


def test_stage_receipt_rejects_lifecycle_drift(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)

    with pytest.raises(runner.ProofFailure, match="lifecycle drifted"):
        runner.persist_stage_receipt(
            proof_root,
            "logical_unload",
            "completed",
            {"ack": True, "still_loaded": False},
        )
    runner.persist_stage_receipt(proof_root, "logical_unload", "started")
    with pytest.raises(runner.ProofFailure, match="lifecycle drifted"):
        runner.persist_stage_receipt(proof_root, "proof", "started")


def test_stage_receipt_rejects_content_bearing_evidence(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir(mode=0o700)

    with pytest.raises(runner.ProofFailure, match="evidence is not typed"):
        runner.persist_stage_receipt(
            proof_root,
            "direct_api",
            "completed",
            {"output": "must not persist"},
        )

    with pytest.raises(runner.ProofFailure, match="evidence is not typed"):
        runner.persist_stage_receipt(
            proof_root,
            "direct_api",
            "completed",
            {
                "elapsed_ms": 12,
                "model": runner.MODEL,
                "request_id_sha256": "a" * 64,
                "usage": {"output_tokens": "must not persist"},
                "console_rendered": True,
                "scheduler_selected": True,
            },
        )


def test_request_inspection_compacts_pretty_cli_json_after_command_completion() -> None:
    runner = _runner()

    expression = runner.request_inspection_expression("resp_fixture")

    assert 'Requests.run(["inspect", "resp_fixture", "--json"])' in expression
    assert "Jason.encode!(Jason.decode!(json))" in expression
    assert expression.index("Requests.run") < expression.index("KAP112_REQUEST_INSPECT_JSON=")


def test_process_diagnostic_is_bounded_and_redacts_secrets() -> None:
    runner = _runner()
    result = subprocess.CompletedProcess(
        ["opencode"],
        1,
        "x" * 1200 + "secret-token",
        "failure secret-token",
    )

    diagnostic = runner.bounded_process_diagnostic(result, secrets=("secret-token",))

    assert "secret-token" not in diagnostic
    assert diagnostic.count("[REDACTED]") == 2
    assert "stdout_length=1212" in diagnostic
    assert "x" * 1001 not in diagnostic


def test_direct_response_drift_reports_bounded_identity() -> None:
    runner = _runner()
    payload = {
        "object": "response",
        "status": "completed",
        "model": runner.MODEL,
        "output_text": "unexpected",
    }

    with pytest.raises(runner.ProofFailure, match=r"length=10 sha256=.*preview='unexpected'"):
        runner.validate_response(payload, "expected")


def test_worker_socket_budget_checks_complete_generated_path(tmp_path: Path) -> None:
    runner = _runner()
    work_root = tmp_path / "r"

    runner.require_worker_socket_path_budget(work_root)

    candidate = runner.worker_socket_dir(work_root) / runner.WORKER_SOCKET_FILENAME_PROBE
    assert len(os.fsencode(candidate)) <= runner.LINUX_UNIX_SOCKET_PATH_MAX_BYTES


def test_worker_socket_budget_rejects_overlong_proof_root(tmp_path: Path) -> None:
    runner = _runner()
    work_root = tmp_path / ("x" * 100)

    with pytest.raises(runner.ProofFailure, match="Unix-socket path budget"):
        runner.require_worker_socket_path_budget(work_root)


def test_logical_load_rejects_unconfirmed_model(tmp_path: Path) -> None:
    runner = _runner()
    runner.run = lambda *_args, **_kwargs: (
        "KAP112_LOGICAL_LOAD_JSON="
        + json.dumps(
            {
                "already_loaded": False,
                "failure_code": "load_failed",
                "loaded": False,
                "model": runner.MODEL,
                "placement_state": "PLACEMENT_STATE_FAILED",
            }
        )
    )

    with pytest.raises(runner.ProofFailure, match="exact logical model load"):
        runner.logical_load(tmp_path, {})


def test_cleanup_removes_only_runner_owned_paths(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir()
    retained = proof_root / "snapshot"
    retained.mkdir()
    artifacts = proof_root / "artifacts"
    artifacts.mkdir()
    (artifacts / "temporary").write_text("artifact")
    token = proof_root / "token"
    token.write_text("secret")
    runner_state = proof_root / "runner-state"
    runner_state.mkdir()
    (runner_state / "temporary").write_text("state")
    args = type("Args", (), {"proof_root": proof_root, "token_file": token})()
    runner.persist_stage_receipt(proof_root, "overflow", "started")
    receipt_path = runner.stage_receipt_path(proof_root)
    receipt_path.with_name(runner.STAGE_RECEIPT_FILENAME + ".tmp").write_text("interrupted")

    runner.cleanup_runner_state(args, remove_artifacts=True)

    assert retained.is_dir()
    assert not artifacts.exists()
    assert not token.exists()
    assert not runner_state.exists()
    assert receipt_path.is_file()
    assert runner.load_stage_receipts(receipt_path)[-1]["stage"] == "overflow"
    assert not receipt_path.with_name(runner.STAGE_RECEIPT_FILENAME + ".tmp").exists()


def test_cleanup_preserves_preexisting_artifacts(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    artifacts = proof_root / "artifacts"
    artifacts.mkdir(parents=True)
    retained = artifacts / "retained"
    retained.write_text("existing")
    args = type("Args", (), {"proof_root": proof_root, "token_file": proof_root / "token"})()

    runner.cleanup_runner_state(args, remove_artifacts=False)

    assert retained.read_text() == "existing"


def test_cleanup_preserves_preexisting_dangling_artifacts(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir()
    artifacts = proof_root / "artifacts"
    artifacts.symlink_to(proof_root / "missing", target_is_directory=True)
    args = type("Args", (), {"proof_root": proof_root, "token_file": proof_root / "token"})()

    runner.cleanup_runner_state(args, remove_artifacts=False)

    assert artifacts.is_symlink()


def test_cleanup_fails_closed_on_dangling_owned_artifacts(tmp_path: Path) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    proof_root.mkdir()
    artifacts = proof_root / "artifacts"
    artifacts.symlink_to(proof_root / "missing", target_is_directory=True)
    args = type("Args", (), {"proof_root": proof_root, "token_file": proof_root / "token"})()

    with pytest.raises(runner.ProofFailure, match="temporary state remains"):
        runner.cleanup_runner_state(args, remove_artifacts=True)

    assert artifacts.is_symlink()


def test_preflight_rejects_dangling_artifact_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runner = _runner()
    proof_root = tmp_path / "proof"
    bundle = proof_root / "bundle"
    proof_root.mkdir(mode=0o700)
    bundle.mkdir()
    (proof_root / "artifacts").symlink_to(proof_root / "missing", target_is_directory=True)
    args = SimpleNamespace(
        repo=tmp_path,
        accepted_commit="head",
        accepted_tree="tree",
        manifest=tmp_path / "manifest.json",
        prepare_only=True,
        proof_root=proof_root,
        bundle_dir=bundle,
        token_file=proof_root / "token",
    )
    manifest = {"identity": {"source_parent": "parent", "opencode": {}}}
    monkeypatch.setattr(runner, "git_identity", lambda _repo: ("head", "tree"))
    monkeypatch.setattr(runner, "verify_manifest_identity", lambda *_args: None)
    monkeypatch.setattr(runner, "verify_snapshot_manifest", lambda *_args: None)
    monkeypatch.setattr(runner, "run", lambda *_args, **_kwargs: "parent")
    monkeypatch.setattr(runner, "verify_opencode", lambda *_args: tmp_path / "opencode")
    monkeypatch.setattr(runner, "require_clear_port", lambda *_args: None)

    with pytest.raises(runner.ProofFailure, match="artifact state already exists"):
        runner.preflight(args, manifest)
