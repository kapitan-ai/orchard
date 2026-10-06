"""Exact source-owned input steering; separate from negotiated output parsing."""

from __future__ import annotations

import json
from importlib.resources import files
from typing import Any

_PROFILES = tuple(
    json.loads(files("orchard_tokenizer").joinpath("effort_profiles.json").read_text())["profiles"]
)


def resolve(
    artifact: str, template: str, tier: str
) -> tuple[dict[str, str], dict[str, Any]] | None:
    if tier not in {"low", "medium", "high"}:
        return None
    for profile in _PROFILES:
        if (profile["model_artifact_digest"], profile["chat_template_digest"]) != (
            artifact,
            template,
        ):
            continue
        native = profile["efforts"].get(tier)
        if not isinstance(native, str) or not native:
            return None
        contract = {
            "mode": "rendered",
            "model_artifact_digest": artifact,
            "chat_template_digest": template,
            "render_contract": profile["render_contract"],
            "render_contract_version": profile["render_contract_version"],
            "native_effort": native,
        }
        args = {
            profile["generation_argument"]["key"]: profile["generation_argument"]["value"],
            profile["effort_argument"]: native,
        }
        return contract, args
    return None
