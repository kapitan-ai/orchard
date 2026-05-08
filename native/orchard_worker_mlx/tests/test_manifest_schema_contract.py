"""Manifest schema contract tests for the MLX worker."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from orchard_worker_mlx.model_loader import (
    _KNOWN_CHAT_TEMPLATE_KEYS,
    _KNOWN_RUNTIME_REQUIREMENTS_KEYS,
    _KNOWN_TOKENIZER_KEYS,
    _KNOWN_TOP_LEVEL_KEYS,
    BundleManifest,
    parse_manifest_json,
)

_REPO_ROOT = Path(__file__).resolve().parents[3]
_CONTRACT = (
    _REPO_ROOT / "apps" / "orchard_shared" / "test" / "fixtures" / "manifest_schema" / "v1.json"
)


def _load_contract() -> dict[str, Any]:
    assert _CONTRACT.is_file(), _CONTRACT
    return json.loads(_CONTRACT.read_text(encoding="utf-8"))


def test_worker_known_keys_match_manifest_schema_contract() -> None:
    contract = _load_contract()

    assert contract["version"] == 1
    assert contract["worker_validates_top_level_keys"] is True
    assert _KNOWN_TOP_LEVEL_KEYS == set(contract["top_level_keys"])

    nested_keys = contract["nested_keys"]
    assert _KNOWN_TOKENIZER_KEYS == set(nested_keys["tokenizer"])
    assert _KNOWN_CHAT_TEMPLATE_KEYS == set(nested_keys["chat_template"])
    assert _KNOWN_RUNTIME_REQUIREMENTS_KEYS == set(nested_keys["runtime_requirements"])

    assert set(contract["worker_validates_nested_keys"]) == {
        "chat_template",
        "runtime_requirements",
        "tokenizer",
    }
    assert "safe_tokenization" not in contract["worker_validates_nested_keys"]


def test_parse_manifest_json_accepts_top_level_safe_tokenization_without_parsing_it() -> None:
    payload = {
        "artifact_layout": "directory",
        "capabilities": ["chat"],
        "chat_template": {
            "path": "chat_template.jinja",
            "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        },
        "entrypoint": "weights/",
        "format": "mlx",
        "kv_cache_bytes_per_token": 16384,
        "max_context_tokens": 4096,
        "model_id": "test-org/tiny-llm",
        "prefill_workspace_bytes_per_token": 2048,
        "resident_memory_bytes": 2048000,
        "runtime_requirements": {
            "adapter": "mlx_lm",
            "min_agent_capability": "mlx",
        },
        "safe_tokenization": {
            "catalog_sha256": "0" * 64,
            "catalog_source": {
                "added_tokens_count": 1,
                "additional_special_tokens_count": 2,
                "chat_template_literals_count": 3,
                "config_singletons_count": 4,
                "extra_count": 1,
                "wrapper_tool_markers_count": 5,
            },
            "compatible": False,
            "control_tokens": ["<|im_start|>", "<|im_end|>"],
            "extra_control_token_strings": ["<|tool_call|>"],
            "incompatibility_reason": {
                "category": "dual_render_mismatch",
                "first_diff_offset": 17,
                "leaf_class": "assistant_message",
                "literal": "<|im_start|>",
                "sentinel_index": 0,
            },
            "template_compatible": False,
        },
        "sha256": "1" * 64,
        "size_bytes": 1024000,
        "tokenizer": {
            "config_path": "tokenizer_config.json",
            "kind": "huggingface_tokenizer_json",
            "path": "tokenizer.json",
        },
        "version": "mlx-q4-v1",
    }

    manifest = parse_manifest_json(json.dumps(payload))

    assert isinstance(manifest, BundleManifest)
    assert manifest.model_id == "test-org/tiny-llm"
    assert manifest.tokenizer.path == "tokenizer.json"
    assert not hasattr(manifest, "safe_tokenization")
