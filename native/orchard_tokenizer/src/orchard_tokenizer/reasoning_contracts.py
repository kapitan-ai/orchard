"""Closed exact-identity render contracts for negotiated reasoning requests."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final, TypeAlias

ContractKey: TypeAlias = tuple[str, str]
PolicyKey: TypeAlias = tuple[str, str]
ContractRegistration: TypeAlias = Mapping[str, object]

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
    template_arguments: dict[str, bool]


def resolve(
    model_artifact_digest: str,
    chat_template_digest: str,
    generation_policy: str,
    projection: str,
) -> ResolvedReasoningContract | None:
    """Return the registered exact contract, or ``None`` when unsupported."""
    registration = REASONING_RENDER_CONTRACTS.get(
        (model_artifact_digest, chat_template_digest), {}
    ).get((generation_policy, projection))

    if registration is None:
        return None

    return _resolved_contract(
        model_artifact_digest,
        chat_template_digest,
        registration,
    )


def _resolved_contract(
    model_artifact_digest: str,
    chat_template_digest: str,
    registration: ContractRegistration,
) -> ResolvedReasoningContract:
    if set(registration) != _REQUIRED_REGISTRATION_FIELDS:
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

    return ResolvedReasoningContract(
        effective_contract={
            "mode": "negotiated",
            "model_artifact_digest": model_artifact_digest,
            "chat_template_digest": chat_template_digest,
            **identity,
        },
        template_arguments=dict(template_arguments),
    )
