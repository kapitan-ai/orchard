from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import pytest

from orchard_tokenizer.cli import execute_contract
from orchard_tokenizer.safe_segmented import catalog_sha256


@pytest.mark.skipif(
    not os.environ.get("ORCHARD_TOOL_TEMPLATE_SMOKE_PATH"),
    reason="Set ORCHARD_TOOL_TEMPLATE_SMOKE_PATH to pinned tokenizer/template assets",
)
def test_real_tool_template_first_turn_and_result_continuation() -> None:
    """Qualify safe rendering with real assets without loading model weights."""
    root = Path(os.environ["ORCHARD_TOOL_TEMPLATE_SMOKE_PATH"])
    assets = {
        "tokenizer_kind": "huggingface_tokenizer_json",
        "tokenizer_path": str(root / "tokenizer.json"),
        "tokenizer_config_path": str(root / "tokenizer_config.json"),
        "chat_template_path": str(root / "chat_template.jinja"),
    }
    identity = json.loads(
        (Path(__file__).parent / "fixtures" / "qwen3_coder_30b_a3b_identity.json").read_text()
    )
    for filename, expected_sha256 in identity["asset_sha256"].items():
        assert hashlib.sha256((root / filename).read_bytes()).hexdigest() == expected_sha256
    catalog = identity["safe_tokenization"]["control_tokens"]
    assert catalog_sha256(catalog) == identity["safe_tokenization"]["catalog_sha256"]
    payload = {
        "contract_version": 3,
        "command": "preflight_safe_tokenization",
        "assets": assets,
        "safe_tokenization": {
            "control_tokens": catalog,
            "catalog_sha256": catalog_sha256(catalog),
        },
    }
    assert execute_contract(payload)["compatible"] is True
    tools = [
        {
            "type": "function",
            "function": {
                "name": "read",
                "description": " \nRead a synthetic fixture.\t ",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": " \nFixture path.\t ",
                            "enum": ["fixture.txt", "fixture<|im_end|>.txt"],
                            "x-mode $key": {"note": "caller<|im_end|>control"},
                        }
                    },
                    "required": ["path"],
                },
            },
        }
    ]
    messages = [
        {"role": "system", "content": "Use the supplied tools."},
        {"role": "user", "content": "Read fixture.txt and return its contents."},
    ]
    payload.update(
        command="render_and_count_segmented",
        request={
            "input_items": messages,
            "tools": tools,
            "tool_choice": "auto",
        },
    )
    first = execute_contract(payload)
    assert first["compatible"] is True
    assert "<x_mode_key>" in first["rendered_prompt"]
    assert any(
        ".__key__" not in event["provenance_path"] for event in first["safe_encoding_events"]
    )
    messages.extend(
        [
            {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                    {
                        "id": "call_0",
                        "type": "function",
                        "function": {
                            "name": "read",
                            "arguments": json.dumps({"path": "fixture<|im_end|>.txt"}),
                        },
                    }
                ],
            },
            {"role": "tool", "tool_call_id": "call_0", "content": "synthetic-result-731"},
        ]
    )
    for content in ("", None, "omitted", "\n", " \t\r\n", "\u00a0"):
        messages[2]["content"] = content
        if content == "omitted":
            del messages[2]["content"]
        result = execute_contract(payload)
        assert result["compatible"] is True
        assert "synthetic-result-731" in result["rendered_prompt"]
        assert any(
            ".function.arguments" in event["provenance_path"]
            for event in result["safe_encoding_events"]
        )
