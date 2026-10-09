"""SPEC.md 7.2.9: contract5 rendered-effort IDs are the IDs the bridge admits."""

import hashlib
import json
from pathlib import Path
from uuid import uuid4

import pytest
from orchard_tokenizer import effort_contracts
from orchard_tokenizer.cli import execute_contract
from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, runtime_pb2
from tokenizers import Tokenizer

from orchard_tensorfold_http.admission import ExperimentProfile, admit_history
from orchard_tensorfold_http.rendering import bind_chat_template

ARTIFACT = "2" * 64
TOKENIZER = (
    Path(__file__).resolve().parents[3]
    / "apps/orchard_controller/test/fixtures/tokenizer/minimal_hf/tokenizer.json"
)
TOOLS = [{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}]
HISTORIES = {
    "plain": [{"role": "user", "content": "hello orchard"}],
    "tool_continuation": [
        {"role": "user", "content": "read a.py"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "read", "arguments": '{"file":"a.py"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_1", "name": "read", "content": "source_ok"},
    ],
}


@pytest.fixture
def assets(tmp_path, monkeypatch):
    # Synthetic model-free template; not a vendor-template qualification.
    template = tmp_path / "chat_template.jinja"
    template.write_text(
        "{{ messages | tojson }}{{ tools | tojson }}"
        "{{ enable_thinking }}{{ reasoning_effort }}"
        "{% if add_generation_prompt %} <think>{% endif %}"
    )
    config = tmp_path / "tokenizer_config.json"
    config.write_text("{}")
    template_digest = hashlib.sha256(template.read_bytes()).hexdigest()
    monkeypatch.setattr(
        effort_contracts,
        "_PROFILES",
        (
            {
                "model_artifact_digest": ARTIFACT,
                "chat_template_digest": template_digest,
                "render_contract": "fixture_native_effort",
                "render_contract_version": "1",
                "generation_argument": {"key": "enable_thinking", "value": True},
                "effort_argument": "reasoning_effort",
                "default_effort": "medium",
                "efforts": {"low": "low", "medium": "medium", "high": "high", "xhigh": "high"},
            },
        ),
    )
    return template, config, template_digest


def helper_tokenization(assets, messages, tools):
    template, config, template_digest = assets
    return execute_contract(
        {
            "contract_version": 5,
            "command": "render_and_count_effort",
            "assets": {
                "tokenizer_kind": "huggingface_tokenizer_json",
                "tokenizer_path": str(TOKENIZER),
                "tokenizer_config_path": str(config),
                "chat_template_path": str(template),
                "model_artifact_digest": ARTIFACT,
                "chat_template_digest": template_digest,
            },
            "request": {
                "input_items": messages,
                "tools": tools,
                "tool_choice": None,
                "reasoning": {
                    "generation_policy": "enabled",
                    "projection": "legacy_blended",
                    "reasoning_effort": "medium",
                    "source": "explicit_public",
                    "effective_contract": effort_contracts.resolve(
                        ARTIFACT, template_digest, "medium"
                    )[0],
                },
            },
        }
    )


def profile_for(assets):
    _template, config, template_digest = assets
    return ExperimentProfile(
        profile_id="synthetic-medium",
        model_id="synthetic-qwen",
        version="1" * 64,
        artifact_digest=ARTIFACT,
        template_digest=template_digest,
        tokenizer_config_digest=hashlib.sha256(config.read_bytes()).hexdigest(),
        max_projection_bytes=10000,
        max_input_tokens=7168,
        max_output_tokens=1024,
        max_context_tokens=8192,
        vocabulary_size=Tokenizer.from_file(str(TOKENIZER)).get_vocab_size(),
        max_output_bytes=10000,
        max_event_bytes=1000,
        max_request_seconds=90,
    )


def bound_request(profile, tokenization, messages, tools):
    projection = {**profile.binding("owned"), "messages": messages, "tools": tools}
    return runtime_pb2.ExecuteInferenceRequest(
        request_id="chatcmpl-" + str(uuid4()),
        model_id=profile.model_id,
        version=profile.version,
        rendered_prompt_utf8=tokenization["rendered_prompt"].encode(),
        input_tokens=tokenization["input_token_count"],
        prompt_token_ids=tokenization.get("prompt_token_ids", []),
        deadline_unix_ms=1_089_800,
        params=common_pb2.GenerationParams(
            max_output_tokens=1024, temperature=1, top_p=0.95, tools_json=json.dumps(tools).encode()
        ),
        tensorfold_history_projection_json=json.dumps(projection).encode(),
    )


def admit(assets, request, profile):
    template, config, template_digest = assets
    render = bind_chat_template(
        template,
        config,
        template_digest=template_digest,
        config_digest=profile.tokenizer_config_digest,
    )
    tokenizer = Tokenizer.from_file(str(TOKENIZER))
    return admit_history(
        request,
        profile=profile,
        incarnation="owned",
        render=render,
        encode=lambda text: tokenizer.encode(text, add_special_tokens=False).ids,
        wall_seconds=1000,
        monotonic_seconds=0,
    )


@pytest.mark.parametrize("history", sorted(HISTORIES))
def test_spec_7_2_9_contract5_ids_are_admitted_for_rendered_medium(assets, history):
    messages = HISTORIES[history]
    tools = TOOLS if history == "tool_continuation" else []
    tokenization = helper_tokenization(assets, messages, tools)
    profile = profile_for(assets)

    admitted = admit(assets, bound_request(profile, tokenization, messages, tools), profile)

    assert list(admitted.prompt_ids) == tokenization["prompt_token_ids"]
    assert 0 < admitted.history_len < len(admitted.prompt_ids)


def test_retry_9_regression_ids_cleared_before_the_bridge_are_rejected(assets):
    messages = HISTORIES["plain"]
    tokenization = helper_tokenization(assets, messages, [])
    profile = profile_for(assets)
    request = bound_request(profile, tokenization, messages, [])
    del request.prompt_token_ids[:]

    with pytest.raises(BackendError) as error:
        admit(assets, request, profile)

    assert (error.value.code, error.value.message) == (
        "invalid_history_projection",
        "invalid authoritative token IDs",
    )


def test_single_changed_id_is_rejected_as_prompt_mismatch(assets):
    messages = HISTORIES["plain"]
    tokenization = helper_tokenization(assets, messages, [])
    profile = profile_for(assets)
    request = bound_request(profile, tokenization, messages, [])
    request.prompt_token_ids[0] = (request.prompt_token_ids[0] + 1) % profile.vocabulary_size

    with pytest.raises(BackendError, match="authoritative rendered prompt mismatch"):
        admit(assets, request, profile)
