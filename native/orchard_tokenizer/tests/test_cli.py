from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import sentencepiece as sentencepiece

from orchard_tokenizer import __version__
from orchard_tokenizer.cli import (
    build_error_response,
    build_success_response,
    main,
)


def test_build_success_response_returns_structured_result() -> None:
    payload = build_success_response("system orchard\nassistant", 2)

    assert payload == {
        "contract_version": 2,
        "ok": True,
        "result": {
            "rendered_prompt": "system orchard\nassistant",
            "input_token_count": 2,
        },
    }


def test_build_error_response_returns_stable_category_shape() -> None:
    payload = build_error_response("missing_assets", "tokenizer asset is missing")

    assert payload == {
        "contract_version": 2,
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
    sentencepiece.SentencePieceTrainer.train(
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
    return (
        Path(__file__).resolve().parents[3]
        / "apps"
        / "orchard_controller"
        / "test"
        / "fixtures"
        / "tokenizer"
        / "minimal_hf"
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
