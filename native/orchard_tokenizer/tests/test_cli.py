from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

import sentencepiece as sentencepiece
from tokenizers import Tokenizer
from tokenizers.decoders import ByteLevel as ByteLevelDecoder
from tokenizers.models import BPE
from tokenizers.pre_tokenizers import ByteLevel
from tokenizers.trainers import BpeTrainer

from orchard_tokenizer import __version__
from orchard_tokenizer.cli import (
    build_error_response,
    build_success_response,
    main,
)
from orchard_tokenizer.safe_segmented import SafeSegmentedError, catalog_sha256


def test_build_success_response_returns_structured_result() -> None:
    payload = build_success_response("system orchard\nassistant", 2)

    assert payload == {
        "contract_version": 3,
        "ok": True,
        "result": {
            "rendered_prompt": "system orchard\nassistant",
            "input_token_count": 2,
        },
    }


def test_build_error_response_returns_stable_category_shape() -> None:
    payload = build_error_response("missing_assets", "tokenizer asset is missing")

    assert payload == {
        "contract_version": 3,
        "ok": False,
        "error": {
            "category": "missing_assets",
            "message": "tokenizer asset is missing",
        },
    }


def test_main_renders_and_counts_huggingface_fixture(capsys) -> None:
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=fixture_root() / "chat_template.jinja",
    )

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response == {
        "contract_version": 2,
        "ok": True,
        "result": {
            "rendered_prompt": "system orchard\nuser hello orchard\nassistant",
            "input_token_count": 6,
        },
    }


def test_main_supports_sentencepiece_tokenizer_models(tmp_path: Path, capsys) -> None:
    corpus_path = tmp_path / "corpus.txt"
    corpus_path.write_text("system orchard\nuser hello orchard\nassistant\n", encoding="utf-8")

    model_prefix = tmp_path / "tokenizer"
    sentencepiece_train = cast(Any, sentencepiece.SentencePieceTrainer).train
    sentencepiece_train(
        input=str(corpus_path),
        model_prefix=str(model_prefix),
        vocab_size=32,
        model_type="bpe",
        bos_id=-1,
        eos_id=-1,
        pad_id=-1,
        unk_id=0,
        character_coverage=1.0,
        hard_vocab_limit=False,
    )

    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "{{ (prompt_lines + ['assistant']) | join('\\n') }}\n", encoding="utf-8"
    )

    payload = tokenization_payload(
        tokenizer_kind="sentencepiece_tokenizer_model",
        tokenizer_path=model_prefix.with_suffix(".model"),
        chat_template_path=chat_template_path,
    )

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["rendered_prompt"] == "system orchard\nuser hello orchard\nassistant"

    processor = sentencepiece.SentencePieceProcessor()
    processor.Load(str(model_prefix.with_suffix(".model")))
    expected_count = len(processor.EncodeAsIds(response["result"]["rendered_prompt"]))
    assert response["result"]["input_token_count"] == expected_count


def test_main_supports_hf_strftime_now_global(tmp_path: Path, capsys) -> None:
    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "{{ strftime_now('%Y') }}:{{ messages[1]['content'] }}",
        encoding="utf-8",
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=chat_template_path,
    )

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    rendered = response["result"]["rendered_prompt"]
    year, suffix = rendered.split(":", 1)
    assert year.isdigit()
    assert len(year) == 4
    assert suffix == "hello orchard"


def test_main_reports_hf_raise_exception_as_invalid_input(tmp_path: Path, capsys) -> None:
    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "{{ raise_exception('Only user and assistant roles are supported!') }}",
        encoding="utf-8",
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=chat_template_path,
    )

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert "chat template rejected request" in response["error"]["message"]
    assert "Only user and assistant roles are supported!" in response["error"]["message"]
    assert "undefined" not in response["error"]["message"]


def test_main_returns_missing_assets_for_missing_tokenizer_file(capsys) -> None:
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "missing-tokenizer.json",
        chat_template_path=fixture_root() / "chat_template.jinja",
    )

    assert main(["--request-json", json.dumps(payload)]) == 3

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"


def test_main_returns_invalid_input_for_unsupported_content_parts(capsys) -> None:
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=fixture_root() / "chat_template.jinja",
    )
    payload["request"]["input_items"][1]["content"] = [{"type": "image", "url": "file:///tmp/x"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"


def test_main_prints_version(capsys) -> None:
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == __version__


def fixture_root() -> Path:
    return tokenizer_fixture_root() / "minimal_hf"


def divergent_fixture_root() -> Path:
    return tokenizer_fixture_root() / "minimal_hf_template_divergent"


def tokenizer_fixture_root() -> Path:
    return (
        Path(__file__).resolve().parents[3]
        / "apps"
        / "orchard_controller"
        / "test"
        / "fixtures"
        / "tokenizer"
    )


def tokenization_payload(
    *,
    tokenizer_kind: str,
    tokenizer_path: Path,
    chat_template_path: Path,
    contract_version: int = 2,
) -> dict[str, Any]:
    return {
        "contract_version": contract_version,
        "command": "render_and_count",
        "assets": {
            "tokenizer_kind": tokenizer_kind,
            "tokenizer_path": str(tokenizer_path),
            "chat_template_path": str(chat_template_path),
        },
        "request": {
            "input_items": [
                {"role": "system", "content": "orchard"},
                {"role": "user", "content": [{"type": "text", "text": "hello orchard"}]},
            ]
        },
    }


# ---------------------------------------------------------------------------
# Special-token extraction & undefined-variable hardening (P1-2 / P2-3)
# ---------------------------------------------------------------------------


def _make_bundle(
    tmp_path: Path,
    *,
    template: str,
    tokenizer_config: dict[str, Any] | None = None,
) -> dict[str, Path]:
    """Create a minimal test bundle with optional tokenizer_config.json."""
    # Reuse the shared HF tokenizer fixture for token counting.
    tok_src = fixture_root() / "tokenizer.json"
    tok_dst = tmp_path / "tokenizer.json"
    tok_dst.write_bytes(tok_src.read_bytes())

    tmpl_path = tmp_path / "chat_template.jinja"
    tmpl_path.write_text(template, encoding="utf-8")

    if tokenizer_config is not None:
        cfg_path = tmp_path / "tokenizer_config.json"
        cfg_path.write_text(json.dumps(tokenizer_config), encoding="utf-8")

    return {"tokenizer_path": tok_dst, "chat_template_path": tmpl_path}


def test_special_tokens_extracted_from_tokenizer_config(tmp_path: Path, capsys) -> None:
    """Template referencing bos_token and eos_token renders correctly
    when tokenizer_config.json provides them (both string and dict forms)."""
    bundle = _make_bundle(
        tmp_path,
        template="{{ bos_token }}{{ messages[0]['content'] }}{{ eos_token }}",
        tokenizer_config={
            "bos_token": "<s>",
            "eos_token": {"content": "</s>"},
        },
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=bundle["tokenizer_path"],
        chat_template_path=bundle["chat_template_path"],
    )

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["rendered_prompt"] == "<s>orchard</s>"


def test_required_special_tokens_fail_when_config_missing(tmp_path: Path, capsys) -> None:
    """Template referencing bos_token fails deterministically when
    tokenizer_config.json is absent."""
    bundle = _make_bundle(
        tmp_path,
        template="{{ bos_token }}hello",
        tokenizer_config=None,  # no config file
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=bundle["tokenizer_path"],
        chat_template_path=bundle["chat_template_path"],
    )

    assert main(["--request-json", json.dumps(payload)]) == 3
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"
    assert "bos_token" in response["error"]["message"]


def test_required_special_tokens_fail_when_config_lacks_key(tmp_path: Path, capsys) -> None:
    """Template referencing eos_token fails when tokenizer_config.json
    exists but does not contain the required key."""
    bundle = _make_bundle(
        tmp_path,
        template="{{ eos_token }}done",
        tokenizer_config={"bos_token": "<s>"},  # eos_token missing
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=bundle["tokenizer_path"],
        chat_template_path=bundle["chat_template_path"],
    )

    assert main(["--request-json", json.dumps(payload)]) == 3
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"
    assert "eos_token" in response["error"]["message"]


def test_optional_undefined_variables_tolerated(tmp_path: Path, capsys) -> None:
    """Templates referencing optional vars like 'tools' succeed without error
    even when those variables are not supplied."""
    bundle = _make_bundle(
        tmp_path,
        template=(
            "tools_defined={{ tools is defined }} "
            "tools_len={{ tools | length }} "
            "tool_choice_is_none={{ tool_choice is none }}\n"
            "{%- if tools %}TOOLS{% endif %}"
            "{{ messages[0]['content'] }}"
        ),
        tokenizer_config=None,  # no config needed; no required tokens referenced
    )
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=bundle["tokenizer_path"],
        chat_template_path=bundle["chat_template_path"],
    )

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert (
        "tools_defined=True tools_len=0 tool_choice_is_none=True"
        in response["result"]["rendered_prompt"]
    )
    assert "TOOLS" not in response["result"]["rendered_prompt"]
    assert "orchard" in response["result"]["rendered_prompt"]


def test_main_renders_template_with_tools_and_tool_choice_fixture(capsys) -> None:
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=fixture_root() / "chat_template_tools.jinja",
    )
    payload["request"]["tools"] = [{"type": "function", "function": {"name": "lookup_weather"}}]
    payload["request"]["tool_choice"] = {
        "type": "function",
        "function": {"name": "lookup_weather"},
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert (
        "tools_defined=True tools_len=1 tool_choice_is_none=False"
        in response["result"]["rendered_prompt"]
    )
    assert "tool lookup_weather" in response["result"]["rendered_prompt"]


def test_main_accepts_contract_v1_payloads_for_backward_compatibility(capsys) -> None:
    payload = tokenization_payload(
        tokenizer_kind="huggingface_tokenizer_json",
        tokenizer_path=fixture_root() / "tokenizer.json",
        chat_template_path=fixture_root() / "chat_template.jinja",
        contract_version=1,
    )

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["contract_version"] == 1


def test_main_extract_catalog_rejects_contract_v2(capsys, tmp_path: Path) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    payload = {
        "contract_version": 2,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 2
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["contract_version"] == 2
    assert response["error"]["category"] == "invalid_input"
    assert (
        response["error"]["message"]
        == "extract_safe_tokenization_catalog requires contract_version 3"
    )


def test_main_extracts_safe_tokenization_catalog(capsys, tmp_path: Path) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text(
        json.dumps(
            {
                "chat_template": [
                    {"name": "non-default", "template": "<ignored_first>"},
                    {"name": "default", "template": "<from_default>"},
                ]
            }
        ),
        encoding="utf-8",
    )

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
        },
        "options": {"tool_parser_type": "qwen2"},
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response == {
        "contract_version": 3,
        "ok": True,
        "result": {
            "control_tokens_chat_template": ["<from_default>"],
            "control_tokens_wrapper_tool": ["</tool_call>", "<tool_call>"],
            "chat_template_literals_count": 1,
            "wrapper_tool_markers_count": 2,
        },
    }


def test_main_extracts_safe_tokenization_catalog_from_template_only(capsys, tmp_path: Path) -> None:
    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "prefix {{ '<|template_only|>' }} suffix",
        encoding="utf-8",
    )

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["control_tokens_chat_template"] == ["<|template_only|>"]
    assert response["result"]["chat_template_literals_count"] == 1


def test_main_extract_catalog_excludes_non_rendered_control_constants(
    capsys, tmp_path: Path
) -> None:
    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "{{ '</tool_call>' }}{% set marker = '<non_rendered_set>' %}",
        encoding="utf-8",
    )

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["control_tokens_chat_template"] == ["</tool_call>"]
    assert response["result"]["chat_template_literals_count"] == 1


def test_main_extract_catalog_includes_attribute_xml_control_tags(capsys, tmp_path: Path) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        '<tool_call type="function">{{ messages[0]["content"] }}</tool_call>',
        encoding="utf-8",
    )

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["control_tokens_chat_template"] == [
        "</tool_call>",
        '<tool_call type="function">',
    ]
    assert response["result"]["chat_template_literals_count"] == 2


def test_main_extract_catalog_includes_closing_control_tags(capsys, tmp_path: Path) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "<s>{{ messages[0]['content'] }}</s><tool_call></tool_call>",
        encoding="utf-8",
    )

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["control_tokens_chat_template"] == [
        "</s>",
        "</tool_call>",
        "<s>",
        "<tool_call>",
    ]


def test_main_extract_catalog_counts_raw_observations_before_dedupe(capsys, tmp_path: Path) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text("</s></s>", encoding="utf-8")

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["control_tokens_chat_template"] == ["</s>"]
    assert response["result"]["chat_template_literals_count"] == 2


def test_main_extract_catalog_returns_missing_assets_for_missing_chat_template(
    capsys, tmp_path: Path
) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
            "chat_template_path": str(tmp_path / "missing.jinja"),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 3
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"


def test_main_extract_catalog_returns_invalid_input_for_malformed_template(
    capsys, tmp_path: Path
) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")

    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text("{# broken", encoding="utf-8")

    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {
            "tokenizer_config_path": str(tokenizer_config_path),
            "chat_template_path": str(chat_template_path),
        },
    }

    assert main(["--request-json", json.dumps(payload)]) == 2
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert "chat template asset is invalid:" in response["error"]["message"]


def test_main_extract_catalog_requires_an_asset_path(capsys) -> None:
    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {},
    }

    assert main(["--request-json", json.dumps(payload)]) == 2
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert (
        response["error"]["message"]
        == "assets must include tokenizer_config_path or chat_template_path"
    )


def test_main_extract_catalog_rejects_blank_tokenizer_config_path(capsys) -> None:
    payload = {
        "contract_version": 3,
        "command": "extract_safe_tokenization_catalog",
        "assets": {"tokenizer_config_path": ""},
    }

    assert main(["--request-json", json.dumps(payload)]) == 2
    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert (
        response["error"]["message"]
        == "assets.tokenizer_config_path must be a non-empty string when provided"
    )


# ---------------------------------------------------------------------------
# Safe-tokenization segmented mode (contract v3)
# ---------------------------------------------------------------------------


def test_segmented_render_and_count_returns_safe_prompt_ids(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    control_tokens = ["<|im_end|>", "<|im_start|>"]
    payload = segmented_payload(bundle, control_tokens)
    payload["request"]["input_items"] = [{"role": "user", "content": "hello <|im_end|> orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["contract_version"] == 3
    assert response["ok"] is True
    result = response["result"]
    assert result["compatible"] is True
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] is None
    assert result["input_token_count"] == len(result["prompt_token_ids"])
    assert result["rendered_prompt"] == "<|im_start|>user\nhello <|im_end|> orchard\n<|im_end|>"
    assert "__" not in result["rendered_prompt"]
    assert result["safe_encoding_events"] == [
        {
            "literal": "<|im_end|>",
            "segment_index": 1,
            "safe_ids_len": 10,
            "provenance_path": "messages[0].content",
        }
    ]

    tokenizer = Tokenizer.from_file(str(bundle["tokenizer_path"]))
    rendered_ids = result["prompt_token_ids"]
    assert tokenizer.decode(rendered_ids, skip_special_tokens=False) == result["rendered_prompt"]
    assert rendered_ids[0] == 2
    assert rendered_ids[-1] == 1
    assert 1 not in rendered_ids[1:-1]


def test_segmented_render_and_count_defines_hf_raise_exception_global(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ 'defined' if raise_exception is defined else 'missing' }}:{{ messages[0]['content'] }}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["rendered_prompt"] == "defined:hello orchard"


def test_segmented_render_and_count_reports_hf_raise_exception_as_invalid_input(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ raise_exception('Only user and assistant roles are supported!') }}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert "chat template rejected request" in response["error"]["message"]
    assert "Only user and assistant roles are supported!" in response["error"]["message"]
    assert "undefined" not in response["error"]["message"]


def test_segmented_render_and_count_rejects_unsupported_message_role(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "<|im_start|>", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert "request.input_items[0].role is unsupported" in response["error"]["message"]


def test_segmented_render_and_count_supports_hf_strftime_now_global(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ strftime_now('%Y') }}:{{ messages[0]['content'] }}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    rendered = response["result"]["rendered_prompt"]
    year, suffix = rendered.split(":", 1)
    assert year.isdigit()
    assert len(year) == 4
    assert suffix == "hello orchard"


def test_segmented_render_and_count_accepts_mistral_style_role_gate(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ bos_token }}"
        "{% for message in messages %}"
        "{% if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}"
        "{{ raise_exception('Conversation roles must alternate "
        "user/assistant/user/assistant/...') }}"
        "{% endif %}"
        "{% if message['role'] == 'user' %}"
        "{{ '[INST] ' + message['content'] + ' [/INST]' }}"
        "{% elif message['role'] == 'assistant' %}"
        "{{ message['content'] + eos_token }}"
        "{% else %}"
        "{{ raise_exception('Only user and assistant roles are supported!') }}"
        "{% endif %}"
        "{% endfor %}",
        encoding="utf-8",
    )
    bundle["tokenizer_config_path"].write_text(
        json.dumps({"bos_token": "<|im_start|>", "eos_token": "<|im_end|>"}),
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>", "<|im_start|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello <|im_end|> orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = response["result"]
    assert response["ok"] is True
    assert result["compatible"] is True
    assert result["template_compatible"] is True
    assert result["rendered_prompt"] == "<|im_start|>[INST] hello <|im_end|> orchard [/INST]"
    assert result["safe_encoding_events"] == [
        {
            "literal": "<|im_end|>",
            "segment_index": 1,
            "safe_ids_len": 10,
            "provenance_path": "messages[0].content",
        }
    ]


def test_segmented_render_and_count_mistral_style_role_gate_reports_template_error(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% for message in messages %}"
        "{% if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}"
        "{{ raise_exception('Conversation roles must alternate "
        "user/assistant/user/assistant/...') }}"
        "{% endif %}"
        "{{ message['content'] }}"
        "{% endfor %}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "assistant", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "invalid_input"
    assert "chat template rejected request" in response["error"]["message"]
    assert "Conversation roles must alternate" in response["error"]["message"]
    assert "undefined" not in response["error"]["message"]


def test_segmented_render_and_count_still_rejects_trimmed_caller_content(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ messages[0]['content'] | trim }}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_incompatible_template"
    reason = response["error"]["details"]["reason"]
    assert reason["category"] == "dual_render_mismatch"
    assert reason["leaf_class"] == "messages[0].content"
    assert reason["sentinel_index"] == 5


def test_segmented_render_and_count_tools_tojson_omitted_parameters_has_no_null(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        (fixture_root() / "chat_template_tools_tojson.jinja").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    payload = render_payload(
        bundle,
        messages=[{"role": "user", "content": "hello"}],
        tools=[{"type": "function", "function": {"name": "lookup", "description": ""}}],
        control_tokens=["<|im_end|>"],
    )

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    rendered = result["rendered_prompt"]
    assert '"parameters": null' not in rendered
    assert "__" not in rendered


def test_segmented_render_and_count_preserves_message_tool_fields(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% set has_tool_calls = messages[0].get('tool_calls') %}"
        "{% set tool_name = has_tool_calls and "
        "messages[0]['tool_calls'][0]['function']['name'] or '' %}"
        "{% set has_tool_call_id = "
        "messages|length > 1 and messages[1].get('tool_call_id') %}"
        "{% set tool_call_id = has_tool_call_id and "
        "messages[1]['tool_call_id'] or '' %}"
        "{{ tool_name }}:{{ tool_call_id }}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"id": "call_1", "function": {"name": "lookup", "arguments": "{}"}}],
        },
        {"role": "tool", "content": "ok", "tool_call_id": "call_1"},
    ]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["rendered_prompt"] == "lookup:call_1"


def test_segmented_render_and_count_rejects_template_that_fails_sentinel_preflight(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% if messages[0]['content'] == '' %}EMPTY{% else %}"
        "{{ messages[0]['content'] }}{% endif %}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_incompatible_template"
    reason = response["error"]["details"]["reason"]
    assert reason["category"] == "dual_render_mismatch"
    assert reason["leaf_class"] == "messages[0].content"
    assert reason["sentinel_index"] == 0
    assert isinstance(reason["first_diff_offset"], int)


def test_segmented_render_and_count_non_one_env_runs_sentinel_preflight(
    tmp_path: Path, capsys, monkeypatch
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% if messages[0]['content'] == '' %}EMPTY{% else %}"
        "{{ messages[0]['content'] }}{% endif %}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    monkeypatch.setenv("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT", "0")

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_incompatible_template"


def test_segmented_render_and_count_can_skip_sentinel_preflight_by_env(
    tmp_path: Path, capsys, monkeypatch
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% if messages[0]['content'] == '' %}EMPTY{% else %}"
        "{{ messages[0]['content'] }}{% endif %}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "hello orchard"}]

    monkeypatch.setenv("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT", "1")

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    assert response["result"]["rendered_prompt"] == "hello orchard"


def test_segmented_render_and_count_skip_env_preserves_request_guard(
    tmp_path: Path, capsys, monkeypatch
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% if messages[0]['content'] == 'trigger' %}CHANGED{% else %}"
        "{{ messages[0]['content'] }}{% endif %}",
        encoding="utf-8",
    )
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["request"]["input_items"] = [{"role": "user", "content": "trigger"}]

    monkeypatch.setenv("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT", "1")

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_incompatible_template"
    assert response["error"]["details"]["reason"]["category"] == "dual_render_mismatch"


def test_segmented_render_and_count_safely_encodes_preserved_message_name(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "<|im_start|>{{ messages[0]['name'] }}\n{{ messages[0]['content'] }}\n<|im_end|>",
        encoding="utf-8",
    )
    control_tokens = ["<|im_end|>", "<|im_start|>"]
    payload = segmented_payload(bundle, control_tokens)
    payload["request"]["input_items"] = [
        {"role": "user", "name": "alice <|im_end|>", "content": "hello orchard"}
    ]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    result = response["result"]
    assert result["rendered_prompt"] == "<|im_start|>alice <|im_end|>\nhello orchard\n<|im_end|>"
    assert result["safe_encoding_events"] == [
        {
            "literal": "<|im_end|>",
            "segment_index": 1,
            "safe_ids_len": 10,
            "provenance_path": "messages[0].name",
        }
    ]

    tokenizer = Tokenizer.from_file(str(bundle["tokenizer_path"]))
    rendered_ids = result["prompt_token_ids"]
    assert tokenizer.decode(rendered_ids, skip_special_tokens=False) == result["rendered_prompt"]
    assert rendered_ids[0] == 2
    assert rendered_ids[-1] == 1
    assert 1 not in rendered_ids[1:-1]


def test_segmented_render_and_count_safely_encodes_arbitrary_metadata_key(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{% for key, value in messages[0].get('metadata', {}).items() -%}"
        "{{ key }}={{ value }}"
        "{%- endfor %}",
        encoding="utf-8",
    )
    control_tokens = ["<|im_end|>"]
    payload = segmented_payload(bundle, control_tokens)
    payload["request"]["input_items"] = [
        {
            "role": "user",
            "content": "hello orchard",
            "metadata": {"<|im_end|>": "x"},
        }
    ]

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is True
    result = response["result"]
    assert result["rendered_prompt"] == "<|im_end|>=x"
    assert "__" not in result["rendered_prompt"]

    tokenizer = Tokenizer.from_file(str(bundle["tokenizer_path"]))
    rendered_ids = result["prompt_token_ids"]
    assert tokenizer.decode(rendered_ids, skip_special_tokens=False) == result["rendered_prompt"]

    reserved_id = tokenizer.encode("<|im_end|>", add_special_tokens=False).ids[0]
    assert reserved_id not in rendered_ids

    assert any(
        event["literal"] == "<|im_end|>" and event.get("provenance_path", "").endswith(".__key__")
        for event in result["safe_encoding_events"]
    )


def test_segmented_render_and_count_is_v3_only(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["contract_version"] = 2

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["contract_version"] == 2
    assert response["error"]["category"] == "invalid_input"
    assert response["error"]["message"] == "render_and_count_segmented requires contract_version 3"


def test_segmented_render_and_count_rejects_catalog_hash_mismatch(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["safe_tokenization"]["catalog_sha256"] = "0" * 64

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_catalog_hash_mismatch"
    assert response["error"]["details"]["reason"]["category"] == "catalog_hash_mismatch"


def test_segmented_render_and_count_requires_huggingface_tokenizer(tmp_path: Path, capsys) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["assets"]["tokenizer_kind"] = "sentencepiece_tokenizer_model"

    assert main(["--request-json", json.dumps(payload)]) == 4

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "unsupported_tokenizer"


def test_segmented_render_and_count_requires_explicit_tokenizer_config(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = segmented_payload(bundle, ["<|im_end|>"])
    payload["assets"]["tokenizer_config_path"] = str(tmp_path / "missing-tokenizer-config.json")

    assert main(["--request-json", json.dumps(payload)]) == 3

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"


def test_preflight_safe_tokenization_compatible_returns_compatible_true(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>", "<|im_start|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result == {
        "compatible": True,
        "template_compatible": True,
        "incompatibility_reason": None,
    }


def test_preflight_safe_tokenization_tools_tojson_template_returns_compatible_true(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        (fixture_root() / "chat_template_tools_tojson.jinja").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    payload = preflight_payload(bundle, ["<|im_end|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result["compatible"] is True
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] is None


def test_preflight_safe_tokenization_accepts_mistral_style_role_gate(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    bundle["chat_template_path"].write_text(
        "{{ bos_token }}"
        "{% for message in messages %}"
        "{% if (message['role'] == 'user') != (loop.index0 % 2 == 0) %}"
        "{{ raise_exception('Conversation roles must alternate "
        "user/assistant/user/assistant/...') }}"
        "{% endif %}"
        "{% if message['role'] == 'user' %}{{ '[INST] ' + message['content'] + ' [/INST]' }}"
        "{% elif message['role'] == 'assistant' %}{{ message['content'] + eos_token }}"
        "{% else %}{{ raise_exception('Only user and assistant roles are supported!') }}"
        "{% endif %}"
        "{% endfor %}",
        encoding="utf-8",
    )
    bundle["tokenizer_config_path"].write_text(
        json.dumps({"bos_token": "<|im_start|>", "eos_token": "<|im_end|>"}),
        encoding="utf-8",
    )
    payload = preflight_payload(bundle, ["<|im_end|>", "<|im_start|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result == {
        "compatible": True,
        "template_compatible": True,
        "incompatibility_reason": None,
    }


def test_preflight_safe_tokenization_dual_render_mismatch_returns_compatible_false_template_false(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    write_template_that_branches_on_empty(bundle["chat_template_path"])
    payload = preflight_payload(bundle, ["<|im_end|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert_dual_render_mismatch_result(result)


def test_preflight_safe_tokenization_divergent_fixture_returns_dual_render_mismatch(
    capsys,
) -> None:
    bundle = {
        "tokenizer_path": divergent_fixture_root() / "tokenizer.json",
        "tokenizer_config_path": divergent_fixture_root() / "tokenizer_config.json",
        "chat_template_path": divergent_fixture_root() / "chat_template.jinja",
    }
    payload = preflight_payload(bundle, [])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert_dual_render_mismatch_result(result)


def test_preflight_safe_tokenization_per_codepoint_decode_mismatch_returns_compatible_false(
    tmp_path: Path, capsys
) -> None:
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")
    bundle = {
        "tokenizer_path": fixture_root() / "tokenizer.json",
        "tokenizer_config_path": tokenizer_config_path,
        "chat_template_path": fixture_root() / "chat_template.jinja",
    }
    payload = preflight_payload(bundle, ["<|im_start|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result["compatible"] is False
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] == {
        "category": "per_codepoint_decode_mismatch",
        "literal": "<|im_start|>",
    }


def test_preflight_safe_tokenization_reserved_id_persists_returns_compatible_false(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["h"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result["compatible"] is False
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] == {
        "category": "reserved_id_persists",
        "literal": "h",
    }


def test_preflight_safe_tokenization_reserved_id_set_overlap_returns_compatible_false(
    tmp_path: Path, capsys, monkeypatch
) -> None:
    # Classification-only coverage: constructing a compact, otherwise-compatible
    # tokenizer that naturally overlaps a different reserved ID is brittle here.
    def raise_overlap(*_args: Any, **_kwargs: Any) -> None:
        raise SafeSegmentedError(
            "safe_tokenization_incompatible_tokenizer",
            "safe tokenization catalog literal cannot be encoded without reserved IDs",
            reason={"category": "reserved_id_set_overlap", "literal": "overlap"},
            literal="overlap",
        )

    monkeypatch.setattr("orchard_tokenizer.cli.precompute_safe_ids", raise_overlap)
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>", "<|im_start|>"])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result["compatible"] is False
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] == {
        "category": "reserved_id_set_overlap",
        "literal": "overlap",
    }


def test_preflight_safe_tokenization_empty_literal_returns_compatible_false(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, [""])

    assert main(["--request-json", json.dumps(payload)]) == 0

    response = json.loads(capsys.readouterr().out)
    result = assert_single_success_result(response)
    assert result["compatible"] is False
    assert result["template_compatible"] is True
    assert result["incompatibility_reason"] == {
        "category": "empty_literal",
        "literal": "",
    }


def test_preflight_safe_tokenization_catalog_hash_mismatch_returns_error_envelope(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>"])
    payload["safe_tokenization"]["catalog_sha256"] = "0" * 64

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "safe_tokenization_catalog_hash_mismatch"
    assert response["error"]["details"]["reason"]["category"] == "catalog_hash_mismatch"


def test_preflight_safe_tokenization_missing_assets_returns_error_envelope(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>"])
    payload["assets"]["tokenizer_path"] = str(tmp_path / "missing-tokenizer.json")

    assert main(["--request-json", json.dumps(payload)]) == 3

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "missing_assets"


def test_preflight_safe_tokenization_unsupported_command_for_v2_payload_returns_error(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>"])
    payload["contract_version"] = 2

    assert main(["--request-json", json.dumps(payload)]) == 2

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["contract_version"] == 2
    assert response["error"]["category"] == "invalid_input"
    assert response["error"]["message"] == "preflight_safe_tokenization requires contract_version 3"


def test_preflight_safe_tokenization_unsupported_tokenizer_returns_error(
    tmp_path: Path, capsys
) -> None:
    bundle = _make_segmented_bundle(tmp_path)
    payload = preflight_payload(bundle, ["<|im_end|>"])
    payload["assets"]["tokenizer_kind"] = "sentencepiece_tokenizer_model"

    assert main(["--request-json", json.dumps(payload)]) == 4

    response = json.loads(capsys.readouterr().out)
    assert response["ok"] is False
    assert response["error"]["category"] == "unsupported_tokenizer"


def _make_segmented_bundle(tmp_path: Path) -> dict[str, Path]:
    tokenizer_path = _build_segmented_tokenizer(tmp_path)
    tokenizer_config_path = tmp_path / "tokenizer_config.json"
    tokenizer_config_path.write_text("{}", encoding="utf-8")
    chat_template_path = tmp_path / "chat_template.jinja"
    chat_template_path.write_text(
        "<|im_start|>{{ messages[0]['role'] }}\n{{ messages[0]['content'] }}\n<|im_end|>",
        encoding="utf-8",
    )
    return {
        "tokenizer_path": tokenizer_path,
        "tokenizer_config_path": tokenizer_config_path,
        "chat_template_path": chat_template_path,
    }


def _build_segmented_tokenizer(tmp_path: Path) -> Path:
    corpus_path = tmp_path / "corpus.txt"
    corpus_path.write_text("hello orchard user assistant system lookup weather", encoding="utf-8")
    tokenizer = Tokenizer(BPE(unk_token="<unk>"))
    tokenizer.pre_tokenizer = ByteLevel(add_prefix_space=False)
    tokenizer.decoder = ByteLevelDecoder()
    trainer = BpeTrainer(
        vocab_size=300,
        initial_alphabet=ByteLevel.alphabet(),
        special_tokens=["<unk>", "<|im_end|>", "<|im_start|>"],
    )
    tokenizer.train([str(corpus_path)], trainer)
    tokenizer_path = tmp_path / "tokenizer.json"
    tokenizer.save(str(tokenizer_path))
    return tokenizer_path


def segmented_payload(bundle: dict[str, Path], control_tokens: list[str]) -> dict[str, Any]:
    return {
        "contract_version": 3,
        "command": "render_and_count_segmented",
        "assets": {
            "tokenizer_kind": "huggingface_tokenizer_json",
            "tokenizer_path": str(bundle["tokenizer_path"]),
            "tokenizer_config_path": str(bundle["tokenizer_config_path"]),
            "chat_template_path": str(bundle["chat_template_path"]),
        },
        "safe_tokenization": {
            "control_tokens": control_tokens,
            "catalog_sha256": catalog_sha256(control_tokens),
        },
        "request": {
            "input_items": [{"role": "user", "content": "hello orchard"}],
            "tools": [],
            "tool_choice": None,
        },
    }


def preflight_payload(bundle: dict[str, Path], control_tokens: list[str]) -> dict[str, Any]:
    payload = segmented_payload(bundle, control_tokens)
    payload["command"] = "preflight_safe_tokenization"
    del payload["request"]
    return payload


def render_payload(
    bundle: dict[str, Path],
    *,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]],
    control_tokens: list[str],
    tool_choice: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = segmented_payload(bundle, control_tokens)
    payload["request"] = {
        "input_items": messages,
        "tools": tools,
        "tool_choice": tool_choice,
    }
    return payload


def assert_single_success_result(response: dict[str, Any]) -> dict[str, Any]:
    assert response["contract_version"] == 3
    assert response["ok"] is True
    result = response["result"]
    assert "ok" not in result
    assert "result" not in result
    return cast(dict[str, Any], result)


def assert_dual_render_mismatch_result(result: dict[str, Any]) -> None:
    assert result["compatible"] is False
    assert result["template_compatible"] is False
    assert result["incompatibility_reason"]["category"] == "dual_render_mismatch"
    assert result["incompatibility_reason"]["leaf_class"] == "messages[0].content"
    assert result["incompatibility_reason"]["sentinel_index"] == 0
    assert isinstance(result["incompatibility_reason"]["first_diff_offset"], int)


def write_template_that_branches_on_empty(path: Path) -> None:
    path.write_text(
        "{% if messages[0]['content'] == '' %}EMPTY{% else %}"
        "{{ messages[0]['content'] }}{% endif %}",
        encoding="utf-8",
    )
