import hashlib
import json
from pathlib import Path

import pytest
from orchard_tokenizer.cli import (
    TemplateRequestError,
    TokenizerCliError,
    _legacy_template_messages,
    normalize_messages_preserving_message_fields,
    normalize_optional_tools,
    normalize_tool_history,
    render_prompt,
)
from tokenizers import Tokenizer

from orchard_tensorfold_http.rendering import bind_chat_template


@pytest.fixture
def assets(tmp_path):
    template = tmp_path / "chat_template.jinja"
    template.write_text(
        "{{ eos_token }}{{ tools | tojson }}{{ messages | tojson }}"
        "{% if add_generation_prompt %}<think>{% endif %}"
    )
    config = tmp_path / "tokenizer_config.json"
    config.write_text(json.dumps({"eos_token": {"content": "<end>"}}))
    return template, config


def bind(assets):
    template, config = assets
    return bind_chat_template(
        template,
        config,
        template_digest=hashlib.sha256(template.read_bytes()).hexdigest(),
        config_digest=hashlib.sha256(config.read_bytes()).hexdigest(),
    )


def test_canonical_json_html_unicode_and_tool_history_are_preserved(assets):
    render = bind(assets)
    messages = [
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {"id": "call_1", "type": "function", "function": {"name": "read", "arguments": {}}}
            ],
        },
        {"role": "tool", "tool_call_id": "call_1", "content": "<ok> é"},
    ]
    tools = [{"z": 1, "a": "<x> é"}]
    result = render(messages, tools=tools, enable_thinking=True, reasoning_effort="medium")
    assert result.startswith('<end>[{"a": "\\u003cx\\u003e \\u00e9", "z": 1}]')
    assert '"tool_call_id": "call_1"' in result
    assert result.endswith("<think>")


@pytest.mark.parametrize("tools", [[], [{"type": "function", "function": {"name": "read"}}]])
def test_spec_3_4_contract5_public_history_has_exact_bytes_and_fixture_tokens(assets, tools):
    template, config = assets
    template.write_text(
        "{{ eos_token }}{{ messages | tojson }}{{ tools | tojson }}"
        "{{ prompt_lines | tojson }}{{ enable_thinking }}{{ reasoning_effort }}"
        "{% if add_generation_prompt %} <think>{% endif %}"
    )
    messages = [
        {
            "role": "developer",
            "content": [{"type": "text", "text": "hello "}, {"type": "text", "text": "world"}],
        },
        {"role": "assistant", "content": "<think>opaque</think>\n\nfinal", "id": "msg_1"},
        {
            "role": "assistant",
            "content": None,
            "id": "fc_1",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "read", "arguments": '{"path":"<é>"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_1", "name": "read", "content": "kept\n\n"},
    ]
    normalized = _legacy_template_messages(
        normalize_messages_preserving_message_fields(
            normalize_tool_history({"input_items": messages})
        )
    )
    expected = render_prompt(
        normalized,
        [f"{m['role']} {m['content']}" for m in normalized],
        template,
        config,
        tools=normalize_optional_tools(tools),
        tool_choice=None,
        template_arguments={"enable_thinking": True, "reasoning_effort": "medium"},
        strict_template_arguments=True,
    )
    actual = bind(assets)(messages, tools=tools)
    assert actual.encode("utf-8") == expected.encode("utf-8")
    fixture = (
        Path(__file__).resolve().parents[3]
        / "apps/orchard_controller/test/fixtures"
        / "tokenizer/minimal_hf/tokenizer.json"
    )
    tokenizer = Tokenizer.from_file(str(fixture))
    assert (
        tokenizer.encode(actual, add_special_tokens=False).ids
        == tokenizer.encode(expected, add_special_tokens=False).ids
    )


@pytest.mark.parametrize("role", ["system", "developer"])
def test_exact_qwen_template_matches_contract5_history_and_role_admission(assets, role):
    template, config = assets
    fixture_root = (
        Path(__file__).resolve().parents[3] / "apps/orchard_controller/test/fixtures/tokenizer"
    )
    template.write_bytes((fixture_root / "qwen3_8_effort/chat_template.jinja").read_bytes())
    messages = [
        {"role": role, "content": [{"type": "text", "text": "Be exact"}]},
        {"role": "user", "content": "lookup it"},
        {"role": "assistant", "content": "<think>opaque</think>\n\nfinal"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_one",
                    "type": "function",
                    "function": {"name": "lookup", "arguments": '{"q":"value"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": "call_one", "content": "result\n"},
    ]
    normalized = _legacy_template_messages(
        normalize_messages_preserving_message_fields(
            normalize_tool_history({"input_items": messages})
        )
    )

    def reference():
        return render_prompt(
            normalized,
            [f"{m['role']} {m['content']}" for m in normalized],
            template,
            config,
            tools=None,
            tool_choice=None,
            template_arguments={"enable_thinking": True, "reasoning_effort": "medium"},
            strict_template_arguments=True,
        )

    renderer = bind(assets)
    if role == "developer":
        with pytest.raises(TokenizerCliError, match="Unexpected message role"):
            reference()
        with pytest.raises(TemplateRequestError, match="Unexpected message role"):
            renderer(messages, tools=[])
        return
    expected = reference()
    actual = renderer(messages, tools=[])
    assert actual.encode() == expected.encode()
    assert "<think>opaque</think>\n\nfinal" in actual
    tokenizer = Tokenizer.from_file(str(fixture_root / "minimal_hf/tokenizer.json"))
    assert (
        tokenizer.encode(actual, add_special_tokens=False).ids
        == tokenizer.encode(expected, add_special_tokens=False).ids
    )


def test_history_is_exact_prompt_prefix_without_generation_suffix(assets):
    render = bind(assets)
    options = {"enable_thinking": True, "reasoning_effort": "medium"}
    prompt = render([], **options)
    history = render([], add_generation_prompt=False, **options)
    assert prompt == history + "<think>"


def test_startup_template_probe_uses_bound_defaults(assets):
    render = bind(assets)
    assert render([], add_generation_prompt=False) == render(
        [], add_generation_prompt=False, enable_thinking=True, reasoning_effort="medium"
    )


@pytest.mark.parametrize("key", ["reasoning_content", "reasoning", "reasoning_details", "thinking"])
def test_structured_prior_reasoning_is_rejected_before_rendering(assets, key):
    with pytest.raises(ValueError, match="structured prior reasoning is unsupported"):
        bind(assets)([{"role": "assistant", "content": "", key: None}])


@pytest.mark.parametrize("content", ["<think>opaque</think>", "reasoning: caller text", "</think>"])
def test_spec_3_4_ordinary_assistant_content_remains_opaque(assets, content):
    messages = [{"role": "assistant", "content": content}]
    rendered = bind(assets)(messages)
    encoded_messages = rendered.removeprefix("<end>null").removesuffix("<think>")
    assert json.loads(encoded_messages) == messages


@pytest.mark.parametrize("which", ["template", "config"])
def test_snapshot_survives_later_asset_replacement(assets, which):
    render = bind(assets)
    before = render([], enable_thinking=True, reasoning_effort="medium")
    assets[0 if which == "template" else 1].write_text("invalid replacement")
    assert render([], enable_thinking=True, reasoning_effort="medium") == before


@pytest.mark.parametrize("which", ["template_digest", "config_digest"])
def test_unverified_asset_is_rejected(assets, which):
    template, config = assets
    hashes = {
        "template_digest": hashlib.sha256(template.read_bytes()).hexdigest(),
        "config_digest": hashlib.sha256(config.read_bytes()).hexdigest(),
    }
    hashes[which] = "0" * 64
    with pytest.raises(ValueError, match="identity mismatch"):
        bind_chat_template(template, config, **hashes)


@pytest.mark.parametrize(
    "change,error",
    [
        ({"seed": 1}, "unsupported template controls"),
        ({"enable_thinking": False}, "thinking binding mismatch"),
        ({"reasoning_effort": "xhigh"}, "effort binding mismatch"),
        ({"thinking_mode": "chat"}, "thinking mode binding mismatch"),
        ({"add_generation_prompt": 1}, "generation suffix must be boolean"),
    ],
)
def test_mismatched_or_unknown_controls_fail_closed(assets, change, error):
    options = {"enable_thinking": True, "reasoning_effort": "medium", **change}
    with pytest.raises(ValueError, match=error):
        bind(assets)([], **options)
