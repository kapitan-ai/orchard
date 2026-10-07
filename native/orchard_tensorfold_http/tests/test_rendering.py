import hashlib
import json

import pytest

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


@pytest.mark.parametrize("key", ["reasoning_content", "reasoning", "thinking"])
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
