"""The neutral script crosses production event validation, not a protobuf stub."""

import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from agentic_worker import CorpusBackend, decode

from orchard_worker_mlx.service import WorkerRuntimeServicer, build_inference_event


@pytest.mark.parametrize(
    ("script", "kind"),
    [
        ({"text": "west"}, "output_text_delta"),
        ({"usage": [11, 3]}, "usage"),
        ({"complete": "stop", "tokens": [11, 7]}, "completed"),
        ({"fail": "worker_down", "retryable": True}, "failed"),
        (
            {"call_id": "z", "delta": {"index": 1, "function": {"arguments_delta": "3}"}}},
            "tool_call_delta",
        ),
    ],
)
def test_script_event_mapping(script, kind):
    assert build_inference_event(decode(script)).WhichOneof("event") == kind


@pytest.mark.parametrize("tokens,expected_kind", [([11, 7], "completed"), ([11, -1], "failed")])
def test_native_service_validates_script_and_preserves_totals(tmp_path, tokens, expected_kind):
    script = tmp_path / "script.json"
    script.write_text(json.dumps({"events": [{"complete": "stop", "tokens": tokens}]}))
    backend = CorpusBackend(script)
    backend.load_model(model_id="corpus", version="v1", model_path=str(tmp_path))
    request = SimpleNamespace(
        request_id="request",
        rendered_prompt_utf8=b"west",
        cache_affinity_fingerprint="",
        prompt_token_ids=[9, 2],
    )
    events = list(WorkerRuntimeServicer(backend).Generate(request, Mock()))
    assert [event.WhichOneof("event") for event in events] == [expected_kind]
    if expected_kind == "completed":
        assert events[0].completed.usage.input_tokens == 11
        assert events[0].completed.usage.output_tokens == 7
        assert events[0].completed.usage.total_tokens == 18
    else:
        assert events[0].failed.code == "backend_invalid_event"
    assert backend.status()["active_request_count"] == 0
    assert script.with_suffix(".drained").read_text() == "drained"
    assert json.loads(script.with_suffix(".request").read_text())["prompt_token_ids"] == [9, 2]
