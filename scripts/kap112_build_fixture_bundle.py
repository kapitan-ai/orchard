from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any

from kap112_verify_hf_snapshot import verify_snapshot

MODEL_ID = "Qwen/Qwen3.8-27B"
MODEL_REVISION = "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
CHAT_TEMPLATE_SHA256 = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"


def reasoning_contract_template() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "proof_only": True,
        "model_id": MODEL_ID,
        "version": MODEL_REVISION,
        "chat_template_digest": CHAT_TEMPLATE_SHA256,
        "generation_policy": "enabled",
        "projection": "final_only",
        "reasoning_effort": "medium",
        "render_contract": "kap112-qwen3.8-medium",
        "render_contract_version": "1",
        "parser_family": "prompt_opened",
        "parser_version": "v1",
        "runtime_contract_version": "vllm-poc-v1",
        "event_binding_version": "worker-runtime-v1",
        "template_arguments": {"enable_thinking": True},
        "reasoning_effort_template_argument": {
            "key": "reasoning_effort",
            "value": "medium",
        },
        "sampling": {
            "temperature": 1.0,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.0,
            "presence_penalty": 0.0,
            "repetition_penalty": 1.0,
        },
    }


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _chat_template(config: dict[str, Any], snapshot: Path) -> str:
    template_path = snapshot / "chat_template.jinja"
    if template_path.is_file():
        return template_path.read_text()

    configured = config.get("chat_template")
    if isinstance(configured, str) and configured:
        return configured
    if isinstance(configured, list):
        for candidate in configured:
            if (
                isinstance(candidate, dict)
                and candidate.get("name") == "default"
                and isinstance(candidate.get("template"), str)
                and candidate["template"]
            ):
                return candidate["template"]
    raise SystemExit("exact snapshot does not expose one default chat template")


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: kap112_build_fixture_bundle.py SNAPSHOT_DIR EVIDENCE_JSON BUNDLE_DIR"
        )
    snapshot = Path(sys.argv[1]).resolve()
    evidence = Path(sys.argv[2]).resolve()
    bundle = Path(sys.argv[3]).resolve()
    if not snapshot.is_dir() or bundle.exists():
        raise SystemExit("snapshot must exist and bundle destination must be absent")
    verify_snapshot(snapshot, evidence)

    tokenizer_path = snapshot / "tokenizer.json"
    tokenizer_config_path = snapshot / "tokenizer_config.json"
    if not tokenizer_path.is_file() or not tokenizer_config_path.is_file():
        raise SystemExit("exact snapshot tokenizer assets are missing")
    try:
        tokenizer_config = json.loads(tokenizer_config_path.read_text())
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit("exact snapshot tokenizer config is invalid") from None
    if not isinstance(tokenizer_config, dict):
        raise SystemExit("exact snapshot tokenizer config must be an object")

    template = _chat_template(tokenizer_config, snapshot)
    bundle.mkdir(parents=True, mode=0o700)
    (bundle / "weights").mkdir()
    shutil.copyfile(tokenizer_path, bundle / "tokenizer.json")
    tokenizer_config["tool_parser_type"] = "qwen2"
    (bundle / "tokenizer_config.json").write_text(
        json.dumps(tokenizer_config, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    )
    (bundle / "chat_template.jinja").write_text(template)
    (bundle / "weights" / "PROOF_ONLY_PROVIDER_OWNS_WEIGHTS").write_text(
        f"{MODEL_ID}@{MODEL_REVISION}\n"
    )
    if _sha256(bundle / "chat_template.jinja") != CHAT_TEMPLATE_SHA256:
        raise SystemExit("exact snapshot chat template identity drifted")
    (bundle / "reasoning_contract_template.json").write_text(
        json.dumps(reasoning_contract_template(), sort_keys=True, separators=(",", ":")) + "\n"
    )

    payload_bytes = sum(path.stat().st_size for path in bundle.rglob("*") if path.is_file())
    manifest = {
        "model_id": MODEL_ID,
        "version": MODEL_REVISION,
        "format": "mlx",
        "artifact_layout": "directory",
        "entrypoint": "weights/",
        "size_bytes": payload_bytes,
        "resident_memory_bytes": 85_899_345_920,
        "kv_cache_bytes_per_token": 0,
        "prefill_workspace_bytes_per_token": 0,
        "max_context_tokens": 139_264,
        "capabilities": ["chat", "tool_calling"],
        "tokenizer": {
            "kind": "huggingface_tokenizer_json",
            "path": "tokenizer.json",
            "config_path": "tokenizer_config.json",
        },
        "chat_template": {
            "path": "chat_template.jinja",
            "sha256": _sha256(bundle / "chat_template.jinja"),
        },
        "runtime_requirements": {
            "adapter": "vllm_poc",
            "min_agent_capability": "kap112_unmanaged_linux_poc",
        },
    }
    (bundle / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    )

    tool_evidence = {
        "tool_calling": {
            "source_repository": f"https://huggingface.co/{MODEL_ID}",
            "source_revision": MODEL_REVISION,
            "base_model_refs": [],
            "tokenizer_config_sha256": _sha256(bundle / "tokenizer_config.json"),
            "chat_template_sha256": _sha256(bundle / "chat_template.jinja"),
            "tool_parser_type": "qwen2",
            "preflight": {
                "parser_recognized": True,
                "definition_rendered": True,
                "history_rendered": True,
            },
            "result": "declared",
            "runtime_qualification": "not_established",
        }
    }
    (bundle / "tool_capability_evidence.json").write_text(
        json.dumps(tool_evidence, sort_keys=True, separators=(",", ":")) + "\n"
    )
    print(
        json.dumps(
            {
                "bundle": str(bundle),
                "model": f"{MODEL_ID}@{MODEL_REVISION}",
                "proof_only": True,
                "runtime_qualification": "not_established",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
