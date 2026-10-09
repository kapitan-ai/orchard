"""Projection identities cannot replace authoritative history or render controls."""

import json
from dataclasses import replace
from types import SimpleNamespace
from uuid import uuid4

import pytest
from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.generated.cluster.v1 import common_pb2, runtime_pb2

from orchard_tensorfold_http.admission import ExperimentProfile, admit_history
from orchard_tensorfold_http.rendering import normalize_history


@pytest.fixture
def profile():
    return ExperimentProfile(
        profile_id="synthetic-medium",
        model_id="synthetic-qwen",
        version="1" * 64,
        artifact_digest="2" * 64,
        template_digest="3" * 64,
        tokenizer_config_digest="4" * 64,
        max_projection_bytes=10000,
        max_input_tokens=10000,
        max_output_tokens=1000,
        max_context_tokens=11000,
        vocabulary_size=256,
        max_output_bytes=10000,
        max_event_bytes=1000,
        max_request_seconds=10,
    )


def render(messages, *, tools, add_generation_prompt):
    history = json.dumps({"messages": messages, "tools": tools}, sort_keys=True)
    return history + ("<think>" if add_generation_prompt else "")


def encode(text):
    return list(text.encode("utf-8"))


def request_for(profile, incarnation="owned", *, messages=None, tools=None):
    messages = messages or [{"role": "user", "content": "test"}]
    tools = tools or []
    text = render(normalize_history(messages), tools=tools, add_generation_prompt=True)
    projection = {**profile.binding(incarnation), "messages": messages, "tools": tools}
    return runtime_pb2.ExecuteInferenceRequest(
        request_id=str(uuid4()),
        model_id=profile.model_id,
        version=profile.version,
        rendered_prompt_utf8=text.encode(),
        input_tokens=len(encode(text)),
        prompt_token_ids=encode(text),
        deadline_unix_ms=1001000,
        params=common_pb2.GenerationParams(
            max_output_tokens=100, temperature=1, top_p=0.95, tools_json=json.dumps(tools).encode()
        ),
        tensorfold_history_projection_json=json.dumps(projection).encode(),
    )


def admit(request, profile, **options):
    return admit_history(
        request,
        profile=profile,
        incarnation="owned",
        render=render,
        encode=encode,
        wall_seconds=1000,
        monotonic_seconds=20,
        **options,
    )


def change(request, key, value):
    projection = json.loads(request.tensorfold_history_projection_json)
    projection[key] = value
    request.tensorfold_history_projection_json = json.dumps(projection).encode()


def test_verified_history_boundaries_and_deadline(profile):
    request = request_for(profile)
    result = admit(request, profile)
    assert result.prompt_ids == tuple(request.prompt_token_ids)
    assert result.history_len == len(result.prompt_ids) - len("<think>")
    assert result.checkpoint_boundaries == (result.history_len,)
    assert result.deadline_monotonic == 21


@pytest.mark.parametrize("prefix", ["", "chatcmpl-", "resp_"])
def test_spec_3_4_existing_public_request_id_is_preserved(profile, prefix):
    request = request_for(profile)
    request.request_id = prefix + str(uuid4())
    identity = request.request_id
    assert admit(request, profile).prompt_ids == tuple(request.prompt_token_ids)
    assert request.request_id == identity


@pytest.mark.parametrize(
    "identity",
    [
        "chatcmpl-resp_" + str(uuid4()),
        "resp_chatcmpl-" + str(uuid4()),
        "resp_" + "a" * 10000,
        "chatcmpl-" + uuid4().hex,
        "urn:uuid:" + str(uuid4()),
        str(uuid4()) + "\n",
    ],
)
def test_request_identity_forms_are_bounded_and_exact(profile, identity):
    request = request_for(profile)
    request.request_id = identity
    with pytest.raises(BackendError, match="request identity"):
        admit(request, profile)


@pytest.mark.parametrize("prefix", ["chatcmpl-", "resp_"])
def test_spec_3_4_canonical_public_tool_continuation_uses_contract5_history(profile, prefix):
    messages = [
        {
            "role": "developer",
            "content": [{"type": "text", "text": "keep "}, {"type": "text", "text": "bytes"}],
        },
        {"role": "user", "content": "read it"},
        {"role": "assistant", "content": "opaque</think>\n\nfinal"},
        {
            "role": "assistant",
            "content": None,
            "id": "fc_responses_item",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "read", "arguments": '{"path":"é"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_1", "content": "<ok>\n\n"},
    ]
    before = json.dumps(messages)
    request = request_for(profile, messages=messages)
    request.request_id = prefix + str(uuid4())
    assert admit(request, profile).prompt_ids == tuple(request.prompt_token_ids)
    assert json.dumps(messages) == before
    decoded = json.loads(request.rendered_prompt_utf8.removesuffix(b"<think>"))["messages"]
    assert decoded[0]["content"] == "keep bytes"
    assert decoded[2]["content"] == "opaque</think>\n\nfinal"
    assert decoded[3]["content"] == ""
    assert decoded[3]["tool_calls"][0]["function"]["arguments"] == {"path": "é"}
    assert decoded[4]["tool_call_id"] == "call_1"
    assert "id" not in decoded[3]


@pytest.mark.parametrize("arguments", ['{"a":1,"a":2}', "[1]", "NaN", '{"nested":{"a":1,"a":2}}'])
def test_invalid_public_history_arguments_fail_before_rendering(profile, arguments):
    request = request_for(profile)
    change(
        request,
        "messages",
        [
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {"id": "call_1", "function": {"name": "read", "arguments": arguments}}
                ],
            }
        ],
    )
    with pytest.raises(BackendError, match="cannot be rendered"):
        admit(request, profile)


@pytest.mark.parametrize(
    "key,value",
    [
        ("schema_version", True),
        ("schema_version", 2),
        ("profile_id", "other"),
        ("incarnation", "stale"),
        ("model_id", "other"),
        ("version", "0" * 64),
        ("artifact_sha256", "0" * 64),
        ("template_sha256", "0" * 64),
        ("tokenizer_config_sha256", "0" * 64),
        ("enable_thinking", 1),
        ("enable_thinking", False),
        ("reasoning_effort", "high"),
        ("output_projection", "structured"),
        ("unknown_control", 1),
    ],
)
def test_binding_and_unknown_control_fail_before_encoding(profile, key, value):
    request = request_for(profile)
    change(request, key, value)
    with pytest.raises(BackendError):
        admit(request, profile)


@pytest.mark.parametrize("payload", [b"", b"[]", b"{", b"\xff", b'{"a":1,"a":2}', b'{"a":NaN}'])
def test_malformed_projection_fail_closed(profile, payload):
    request = request_for(profile)
    request.tensorfold_history_projection_json = payload
    with pytest.raises(BackendError):
        admit(request, profile)


@pytest.mark.parametrize(
    "field", ["reasoning", "reasoning_content", "reasoning_details", "thinking"]
)
def test_opaque_content_is_preserved_but_structured_prior_is_rejected(profile, field):
    messages = [{"role": "assistant", "content": "opaque</think>\n\nfinal"}]
    request = request_for(profile, messages=messages)
    assert admit(request, profile).prompt_ids == tuple(request.prompt_token_ids)
    messages[0][field] = None
    change(request, "messages", messages)
    with pytest.raises(BackendError, match="structured prior"):
        admit(request, profile)


@pytest.mark.parametrize(
    "field,value",
    [
        ("model_id", "other"),
        ("version", "other"),
        ("request_id", "bad"),
        ("rendered_prompt_utf8", b"substitute"),
        ("input_tokens", 1),
        ("deadline_unix_ms", 1000000),
        ("deadline_unix_ms", 1011000),
        ("return_token_ids", True),
        ("return_logprobs", True),
        ("cache_affinity_fingerprint", "other"),
    ],
)
def test_request_cross_binding_fails(profile, field, value):
    request = request_for(profile)
    setattr(request, field, value)
    with pytest.raises(BackendError):
        admit(request, profile)


def test_internal_projection_is_not_taken_from_public_metadata(profile):
    request = request_for(profile)
    request.metadata_json = request.tensorfold_history_projection_json
    request.tensorfold_history_projection_json = b""
    with pytest.raises(BackendError, match="missing"):
        admit(request, profile)


@pytest.mark.parametrize("choice", [b'"auto"', b'"required"', b'"none"', b'{"name":"read"}'])
def test_unprojected_tool_choice_cannot_be_ignored_by_template(profile, choice):
    request = request_for(profile)
    request.params.tool_choice_json = choice
    with pytest.raises(BackendError, match="tool choice controls"):
        admit(request, profile)


def test_spec_7_2_9_auto_tool_choice_with_declared_tools_is_admitted(profile):
    tools = [{"type": "function", "function": {"name": "read", "parameters": {}}}]
    request = request_for(profile, tools=tools)
    request.params.tool_choice_json = b'"auto"'
    assert admit(request, profile).prompt_ids == tuple(request.prompt_token_ids)


@pytest.mark.parametrize("choice", [b'"required"', b'"none"', b'{"name":"read"}', b'"AUTO"'])
def test_explicit_tool_choice_with_declared_tools_stays_refused(profile, choice):
    tools = [{"type": "function", "function": {"name": "read", "parameters": {}}}]
    request = request_for(profile, tools=tools)
    request.params.tool_choice_json = choice
    with pytest.raises(BackendError, match="tool choice controls"):
        admit(request, profile)


def test_full_natural_tool_history_and_schema_binding(profile):
    tools = [{"type": "function", "function": {"name": "read", "parameters": {}}}]
    messages = [
        {"role": "user", "content": "read it"},
        {
            "role": "assistant",
            "content": "opaque",
            "tool_calls": [
                {"id": "a", "type": "function", "function": {"name": "read", "arguments": "{}"}}
            ],
        },
        {"role": "tool", "tool_call_id": "a", "content": "kept"},
    ]
    request = request_for(profile, messages=messages, tools=tools)
    assert admit(request, profile).prompt_ids == tuple(request.prompt_token_ids)
    request.params.tools_json = b"[]"
    with pytest.raises(BackendError, match="tool schema"):
        admit(request, profile)


def test_redemption_does_not_hash_internal_projection(profile):
    request = request_for(profile)
    request.preparation_redemption.authorization = b"unused"
    with pytest.raises(BackendError, match="redemption"):
        admit(request, profile)


@pytest.mark.parametrize(
    "limits",
    [
        {"max_projection_bytes": 1},
        {"max_input_tokens": 1},
        {"max_output_tokens": 1},
        {"max_context_tokens": 1},
        {"vocabulary_size": 1},
    ],
)
def test_frozen_limits_reject_before_generation(profile, limits):
    with pytest.raises(BackendError):
        admit(request_for(profile), replace(profile, **limits))


def test_prefix_mismatch_cannot_be_used_as_cache_boundary(profile):
    request = request_for(profile)
    with pytest.raises(BackendError, match="prefix"):
        admit_history(
            request,
            profile=profile,
            incarnation="owned",
            render=lambda *a, **kw: render(*a, **kw) if kw["add_generation_prompt"] else "other",
            encode=encode,
            wall_seconds=1000,
            monotonic_seconds=20,
        )


@pytest.mark.parametrize("value", [True, 0, -1, float("inf")])
def test_profile_limits_are_not_coerced(profile, value):
    with pytest.raises(ValueError):
        replace(profile, max_request_seconds=value)


def test_bad_types_or_sampling_never_reach_renderer(profile):
    request = request_for(profile)
    request.params.temperature = float("nan")
    with pytest.raises(BackendError, match="sampling"):
        admit(request, profile)
    malformed = SimpleNamespace(
        **{field.name: getattr(request, field.name) for field in request.DESCRIPTOR.fields}
    )
    malformed.params = SimpleNamespace(max_output_tokens=True, temperature=1, top_p=1)
    with pytest.raises(BackendError):
        admit(malformed, profile)
