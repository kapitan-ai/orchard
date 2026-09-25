"""Closed exact-identity render contracts for negotiated reasoning requests."""

from __future__ import annotations

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
    registration = REASONING_RENDER_CONTRACTS.get(
        (model_artifact_digest, chat_template_digest), {}
    ).get((generation_policy, projection, reasoning_effort))

    if registration is None:
        return None

    return _resolved_contract(
        model_artifact_digest,
        chat_template_digest,
        reasoning_effort,
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
