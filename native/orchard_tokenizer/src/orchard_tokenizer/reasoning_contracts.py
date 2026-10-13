"""Closed exact-identity render contracts for negotiated reasoning requests."""

from __future__ import annotations

import json
import os
import stat
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final, TypeAlias

ContractKey: TypeAlias = tuple[str, str]
PolicyKey: TypeAlias = tuple[str, str, str | None]
ContractRegistration: TypeAlias = Mapping[str, object]
TemplateArgumentValue: TypeAlias = bool | str

_IDENTITY_FIELDS: Final[frozenset[str]] = frozenset(
    {
        "render_contract",
        "render_contract_version",
        "parser_family",
        "parser_version",
        "runtime_contract_version",
        "event_binding_version",
    }
)
_REQUIRED_REGISTRATION_FIELDS: Final[frozenset[str]] = _IDENTITY_FIELDS | {"template_arguments"}
_REQUIRED_EFFORT_REGISTRATION_FIELDS: Final[frozenset[str]] = _REQUIRED_REGISTRATION_FIELDS | {
    "reasoning_effort_template_argument"
}

# Product registrations are intentionally empty until an exact imported artifact,
# template, render/parser/runtime/event versions, and qualification evidence are
# accepted together. This registry is the only authority for negotiated rendering;
# callers cannot supply template keyword arguments.
REASONING_RENDER_CONTRACTS: Final[
    Mapping[ContractKey, Mapping[PolicyKey, ContractRegistration]]
] = {}

_KAP112_EXACT_FIELDS: Final[dict[str, object]] = {
    "schema_version": 1,
    "proof_only": True,
    "model_id": "Qwen/Qwen3.8-27B",
    "version": "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0",
    "chat_template_digest": "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041",
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
    "reasoning_effort_template_argument": {"key": "reasoning_effort", "value": "medium"},
    "sampling": {
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "presence_penalty": 0.0,
        "repetition_penalty": 1.0,
    },
}


@dataclass(frozen=True, slots=True)
class ResolvedReasoningContract:
    """Exact render identity and static template arguments for one policy."""

    effective_contract: dict[str, str]
    template_arguments: dict[str, TemplateArgumentValue]


def resolve(
    model_artifact_digest: str,
    chat_template_digest: str,
    generation_policy: str,
    projection: str,
    reasoning_effort: str | None,
) -> ResolvedReasoningContract | None:
    """Return the registered exact contract, or ``None`` when unsupported."""
    registrations = REASONING_RENDER_CONTRACTS
    kap112_registration = _kap112_registration()
    if kap112_registration is not None:
        key, policy, registration = kap112_registration
        registrations = {**registrations, key: {policy: registration}}

    registration = registrations.get((model_artifact_digest, chat_template_digest), {}).get(
        (generation_policy, projection, reasoning_effort)
    )

    if registration is None:
        return None

    return _resolved_contract(
        model_artifact_digest,
        chat_template_digest,
        reasoning_effort,
        registration,
    )


def _kap112_registration() -> tuple[ContractKey, PolicyKey, ContractRegistration] | None:
    path = os.environ.get("ORCHARD_KAP112_REASONING_CONTRACT")
    if path is None:
        return None
    try:
        file_stat = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(file_stat.st_mode) or stat.S_IMODE(file_stat.st_mode) != 0o600:
            return None
        if file_stat.st_uid != os.getuid():
            return None
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or set(payload) != set(_KAP112_EXACT_FIELDS) | {
        "model_artifact_digest"
    }:
        return None
    if any(payload.get(key) != value for key, value in _KAP112_EXACT_FIELDS.items()):
        return None
    artifact_digest = payload.get("model_artifact_digest")
    if (
        not isinstance(artifact_digest, str)
        or len(artifact_digest) != 64
        or any(character not in "0123456789abcdef" for character in artifact_digest)
    ):
        return None
    identity = {key: payload[key] for key in _IDENTITY_FIELDS}
    registration = {
        **identity,
        "template_arguments": payload["template_arguments"],
        "reasoning_effort_template_argument": payload["reasoning_effort_template_argument"],
    }
    return (
        (artifact_digest, payload["chat_template_digest"]),
        ("enabled", "final_only", "medium"),
        registration,
    )


def _resolved_contract(
    model_artifact_digest: str,
    chat_template_digest: str,
    reasoning_effort: str | None,
    registration: ContractRegistration,
) -> ResolvedReasoningContract:
    required_fields = (
        _REQUIRED_REGISTRATION_FIELDS
        if reasoning_effort is None
        else _REQUIRED_EFFORT_REGISTRATION_FIELDS
    )

    if set(registration) != required_fields:
        raise ValueError("reasoning contract registration has unsupported fields")

    identity = {field: registration.get(field) for field in _IDENTITY_FIELDS}

    if not all(isinstance(value, str) and value for value in identity.values()):
        raise ValueError("reasoning contract registration has invalid identity metadata")

    template_arguments = registration.get("template_arguments")
    if not isinstance(template_arguments, Mapping) or not all(
        isinstance(key, str) and key and isinstance(value, bool)
        for key, value in template_arguments.items()
    ):
        raise ValueError("reasoning contract registration has invalid template arguments")

    resolved_template_arguments: dict[str, TemplateArgumentValue] = dict(template_arguments)

    if reasoning_effort is not None:
        effort_argument = registration.get("reasoning_effort_template_argument")
        if (
            not isinstance(effort_argument, Mapping)
            or set(effort_argument) != {"key", "value"}
            or not isinstance(effort_argument.get("key"), str)
            or not effort_argument["key"]
            or not isinstance(effort_argument.get("value"), str)
            or not effort_argument["value"]
            or effort_argument["key"] in resolved_template_arguments
        ):
            raise ValueError("reasoning contract registration has invalid effort mapping")

        resolved_template_arguments[effort_argument["key"]] = effort_argument["value"]

    return ResolvedReasoningContract(
        effective_contract={
            "mode": "negotiated",
            "model_artifact_digest": model_artifact_digest,
            "chat_template_digest": chat_template_digest,
            **identity,
        },
        template_arguments=resolved_template_arguments,
    )
