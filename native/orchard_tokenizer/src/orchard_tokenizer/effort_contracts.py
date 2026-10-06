"""Exact source-owned input steering; separate from negotiated output parsing."""

from __future__ import annotations

import json
import re
from importlib.resources import files
from typing import Any

_PROFILE_KEYS = {
    "model_artifact_digest",
    "chat_template_digest",
    "render_contract",
    "render_contract_version",
    "generation_argument",
    "effort_argument",
    "efforts",
    "default_effort",
}


def _matches(value: Any, pattern: str) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def _valid_identity(profile: dict[str, Any]) -> bool:
    return (
        _matches(profile["model_artifact_digest"], r"[0-9a-f]{64}")
        and _matches(profile["chat_template_digest"], r"[0-9a-f]{64}")
        and _matches(profile["render_contract"], r"[A-Za-z_][A-Za-z0-9_]*")
        and _matches(profile["render_contract_version"], r"[1-9][0-9]*")
    )


def _valid_arguments(profile: dict[str, Any]) -> bool:
    generation = profile["generation_argument"]
    effort = profile["effort_argument"]
    return (
        isinstance(generation, dict)
        and set(generation) == {"key", "value"}
        and generation["value"] is True
        and _matches(generation["key"], r"[A-Za-z_][A-Za-z0-9_]*")
        and _matches(effort, r"[A-Za-z_][A-Za-z0-9_]*")
        and generation["key"] != effort
    )


def _valid_efforts(efforts: Any) -> bool:
    return (
        isinstance(efforts, dict)
        and bool(efforts)
        and all(valid_value(key) for key in efforts)
        and not {"none", "off", "disabled", "false"}.intersection(efforts)
        and all(isinstance(value, str) and value.strip() for value in efforts.values())
    )


def valid_value(value: Any) -> bool:
    """Bound public syntax without inventing a universal model vocabulary."""
    return _matches(value, r"[a-z][a-z0-9_]{0,31}")


def validate_profiles(registry: Any) -> tuple[dict[str, Any], ...]:
    """Reject malformed or ambiguous registrations before resolving either control."""
    if (
        not isinstance(registry, dict)
        or set(registry) != {"profiles"}
        or not isinstance(registry["profiles"], list)
    ):
        raise ValueError("invalid rendered effort registry")
    identities = set()
    for profile in registry["profiles"]:
        if (
            not isinstance(profile, dict)
            or set(profile) != _PROFILE_KEYS
            or not _valid_identity(profile)
            or not _valid_arguments(profile)
            or not _valid_efforts(profile["efforts"])
            or not valid_value(profile["default_effort"])
            or profile["default_effort"] not in profile["efforts"]
        ):
            raise ValueError("invalid rendered effort registry")
        identity = (profile["model_artifact_digest"], profile["chat_template_digest"])
        if identity in identities:
            raise ValueError("invalid rendered effort registry")
        identities.add(identity)
    return tuple(registry["profiles"])


_PROFILES = validate_profiles(
    json.loads(files("orchard_tokenizer").joinpath("effort_profiles.json").read_text())
)


def resolve(
    artifact: str, template: str, tier: str
) -> tuple[dict[str, str], dict[str, Any]] | None:
    if not valid_value(tier):
        return None
    try:
        profiles = validate_profiles({"profiles": list(_PROFILES)})
    except ValueError:
        return None
    for profile in profiles:
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
