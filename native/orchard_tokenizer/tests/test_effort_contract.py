from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from pathlib import Path

import pytest
from tokenizers import Tokenizer

from orchard_tokenizer import effort_contracts
from orchard_tokenizer.cli import TokenizerCliError, execute_contract


@pytest.fixture
def effort_payload(tmp_path, monkeypatch):
    # Synthetic model-free renderer; this is not a vendor-template qualification.
    template = tmp_path / "chat_template.jinja"
    template.write_text(
        "{% if enable_thinking|default(true) %}"
        "effort={{ reasoning_effort|default('xhigh') }};{% endif %}\n"
        "{% for m in messages %}{{ m.role }} {{ m.content }}"
        "{% if m.tool_calls is defined %}{% for c in m.tool_calls %}"
        " {{ c.id }} {{ c.function.name }} {{ c.function.arguments|tojson }}{% endfor %}{% endif %}"
        "{% if m.tool_call_id is defined %} {{ m.tool_call_id }} {{ m.name }}{% endif %}\n"
        "{% endfor %}assistant"
    )
    digest = hashlib.sha256(template.read_bytes()).hexdigest()
    config = tmp_path / "tokenizer_config.json"
    config.write_text("{}")
    profile = {
        "model_artifact_digest": "a" * 64,
        "chat_template_digest": digest,
        "render_contract": "fixture_native_effort",
        "render_contract_version": "1",
        "generation_argument": {"key": "enable_thinking", "value": True},
        "effort_argument": "reasoning_effort",
        "efforts": {"low": "low", "medium": "medium", "high": "xhigh"},
    }
    monkeypatch.setattr(effort_contracts, "_PROFILES", (profile,))
    tokenizer = (
        Path(__file__).resolve().parents[3]
        / "apps/orchard_controller/test/fixtures/tokenizer/minimal_hf/tokenizer.json"
    )
    assert tokenizer.is_file()
    return {
        "contract_version": 5,
        "command": "render_and_count_effort",
        "assets": {
            "tokenizer_kind": "huggingface_tokenizer_json",
            "tokenizer_path": str(tokenizer),
            "tokenizer_config_path": str(config),
            "chat_template_path": str(template),
            "model_artifact_digest": "a" * 64,
            "chat_template_digest": digest,
        },
        "request": {
            "input_items": [{"role": "user", "content": "hello orchard"}],
            "tools": [],
            "tool_choice": None,
            "reasoning": {
                "generation_policy": "enabled",
                "projection": "legacy_blended",
                "reasoning_effort": "medium",
                "source": "explicit_public",
                "effective_contract": effort_contracts.resolve("a" * 64, digest, "medium")[0],
            },
        },
    }


def select(payload, tier):
    payload = deepcopy(payload)
    reasoning = payload["request"]["reasoning"]
    reasoning["reasoning_effort"] = tier
    reasoning["effective_contract"] = effort_contracts.resolve(
        payload["assets"]["model_artifact_digest"], payload["assets"]["chat_template_digest"], tier
    )[0]
    return payload


@pytest.mark.parametrize("tier,native", [("low", "low"), ("medium", "medium"), ("high", "xhigh")])
def test_exact_native_argument_render_and_real_count(effort_payload, tier, native):
    payload = select(effort_payload, tier)
    result = execute_contract(payload)
    assert result["reasoning"] == payload["request"]["reasoning"]
    assert result["applied_template_arguments"] == {
        "enable_thinking": True,
        "reasoning_effort": native,
    }
    assert result["rendered_prompt"].startswith(f"effort={native};")
    tokenizer = Tokenizer.from_file(payload["assets"]["tokenizer_path"])
    assert result["input_token_count"] == len(tokenizer.encode(result["rendered_prompt"]).ids)


def test_explicit_high_equals_omitted_render_without_changing_omitted_payload(effort_payload):
    explicit = select(effort_payload, "high")
    legacy = deepcopy(explicit)
    legacy["command"] = "render_and_count"
    legacy["contract_version"] = 2
    del legacy["request"]["reasoning"]
    before = deepcopy(legacy)
    rendered = execute_contract(explicit)
    omitted = execute_contract(legacy)
    assert rendered["rendered_prompt"] == omitted["rendered_prompt"]
    assert rendered["input_token_count"] == omitted["input_token_count"]
    assert legacy == before
    assert "reasoning" not in omitted


def test_concurrent_tiers_do_not_share_mutable_arguments(effort_payload):
    tiers = ["medium", "high", "low"] * 16
    payloads = [select(effort_payload, tier) for tier in tiers]
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(execute_contract, payloads))
    for tier, payload, result in zip(tiers, payloads, results, strict=True):
        assert result["reasoning"] == payload["request"]["reasoning"]
        assert result["applied_template_arguments"]["reasoning_effort"] == {"high": "xhigh"}.get(
            tier, tier
        )
    results[0]["applied_template_arguments"]["reasoning_effort"] = "wrong"
    assert (
        execute_contract(effort_payload)["applied_template_arguments"]["reasoning_effort"]
        == "medium"
    )


def test_full_legacy_tool_history_retained(effort_payload):
    effort_payload["request"]["input_items"] += [
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_one",
                    "type": "function",
                    "function": {"name": "inspect", "arguments": '{"file":"a.py"}'},
                }
            ],
        },
        {"role": "tool", "content": "ok", "tool_call_id": "call_one", "name": "inspect"},
    ]
    prompt = execute_contract(effort_payload)["rendered_prompt"]
    assert 'call_one inspect {"file": "a.py"}' in prompt
    assert "tool ok call_one inspect" in prompt


@pytest.mark.parametrize("key", ["reasoning_content", "reasoning", "thinking"])
def test_structured_prior_reasoning_rejected(effort_payload, key):
    effort_payload["request"]["input_items"].append(
        {"role": "assistant", "content": "opaque", key: "private"}
    )
    with pytest.raises(TokenizerCliError, match="structured prior reasoning"):
        execute_contract(effort_payload)


@pytest.mark.parametrize("field", ["model_artifact_digest", "chat_template_digest"])
def test_unknown_exact_tuple_rejects_without_default(effort_payload, field):
    effort_payload["assets"][field] = "b" * 64
    with pytest.raises(TokenizerCliError, match="no exact rendered effort"):
        execute_contract(effort_payload)


def test_native_proof_and_template_bytes_cannot_drift(effort_payload):
    wrong = deepcopy(effort_payload)
    wrong["request"]["reasoning"]["effective_contract"]["native_effort"] = "xhigh"
    with pytest.raises(TokenizerCliError, match="no exact rendered effort"):
        execute_contract(wrong)
    Path(effort_payload["assets"]["chat_template_path"]).write_text("changed")
    with pytest.raises(TokenizerCliError):
        execute_contract(effort_payload)


@pytest.mark.parametrize("tier", [None, "none", "minimal", "xhigh", "MEDIUM", 1, {}, []])
def test_invalid_tier_is_never_remapped(effort_payload, tier):
    effort_payload["request"]["reasoning"]["reasoning_effort"] = tier
    with pytest.raises(TokenizerCliError):
        execute_contract(effort_payload)


@pytest.mark.parametrize("argument", ["messages", "unused_control", "raise_exception"])
def test_bad_registered_argument_cannot_shadow_or_be_ignored(effort_payload, monkeypatch, argument):
    profile = deepcopy(effort_contracts._PROFILES[0])
    profile["effort_argument"] = argument
    monkeypatch.setattr(effort_contracts, "_PROFILES", (profile,))
    with pytest.raises(TokenizerCliError, match="reserved or unreferenced"):
        execute_contract(effort_payload)


def test_registry_refuses_unregistered_or_missing_native_level(effort_payload, monkeypatch):
    assets = effort_payload["assets"]
    assert (
        effort_contracts.resolve(
            assets["model_artifact_digest"], assets["chat_template_digest"], "xhigh"
        )
        is None
    )
    profile = deepcopy(effort_contracts._PROFILES[0])
    del profile["efforts"]["medium"]
    monkeypatch.setattr(effort_contracts, "_PROFILES", (profile,))
    with pytest.raises(TokenizerCliError, match="no exact rendered effort"):
        execute_contract(effort_payload)


@pytest.mark.parametrize("where", ["payload", "assets", "request", "reasoning"])
def test_closed_v5_contract_rejects_unknown_argument_fields(effort_payload, where):
    target = {
        "payload": effort_payload,
        "assets": effort_payload["assets"],
        "request": effort_payload["request"],
        "reasoning": effort_payload["request"]["reasoning"],
    }[where]
    target["chat_template_kwargs"] = {"reasoning_effort": "xhigh"}
    with pytest.raises(TokenizerCliError):
        execute_contract(effort_payload)
