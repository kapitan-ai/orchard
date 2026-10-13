from __future__ import annotations

import json
from pathlib import Path

from orchard_tokenizer.reasoning_contracts import resolve

ARTIFACT_DIGEST = "a" * 64
TEMPLATE_DIGEST = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"


def registration() -> dict[str, object]:
    return {
        "schema_version": 1,
        "proof_only": True,
        "model_id": "Qwen/Qwen3.8-27B",
        "version": "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0",
        "model_artifact_digest": ARTIFACT_DIGEST,
        "chat_template_digest": TEMPLATE_DIGEST,
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


def write_registration(path: Path, payload: dict[str, object], mode: int = 0o600) -> None:
    path.write_text(json.dumps(payload))
    path.chmod(mode)


def resolve_medium() -> object:
    return resolve(ARTIFACT_DIGEST, TEMPLATE_DIGEST, "enabled", "final_only", "medium")


def test_exact_owner_only_runtime_registration_resolves(monkeypatch, tmp_path: Path) -> None:
    path = tmp_path / "reasoning.json"
    write_registration(path, registration())
    monkeypatch.setenv("ORCHARD_KAP112_REASONING_CONTRACT", str(path))

    resolved = resolve_medium()

    assert resolved is not None
    assert resolved.template_arguments == {
        "enable_thinking": True,
        "reasoning_effort": "medium",
    }
    assert resolved.effective_contract["render_contract"] == "kap112-qwen3.8-medium"


def test_runtime_registration_rejects_mode_and_policy_drift(monkeypatch, tmp_path: Path) -> None:
    path = tmp_path / "reasoning.json"
    write_registration(path, registration(), 0o644)
    monkeypatch.setenv("ORCHARD_KAP112_REASONING_CONTRACT", str(path))
    assert resolve_medium() is None

    payload = registration()
    payload["reasoning_effort"] = "xhigh"
    write_registration(path, payload)
    assert resolve_medium() is None


def test_runtime_registration_rejects_artifact_and_sampler_drift(
    monkeypatch, tmp_path: Path
) -> None:
    path = tmp_path / "reasoning.json"
    payload = registration()
    payload["model_artifact_digest"] = "b" * 64
    write_registration(path, payload)
    monkeypatch.setenv("ORCHARD_KAP112_REASONING_CONTRACT", str(path))
    assert resolve_medium() is None

    payload = registration()
    payload["sampling"] = {**payload["sampling"], "temperature": 0.0}
    write_registration(path, payload)
    assert resolve_medium() is None
