"""Internal full-history projection admission for one explicitly selected experiment.

The projection is a separate internal field, never public request metadata. The
configured profile and loaded incarnation supply authority; provider diagnostics
and HTTP health cannot select this implementation.
"""

import json
import math
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from orchard_worker_mlx.backends import BackendError

from orchard_tensorfold_http.rendering import normalize_history


def positive_int(value: int, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


@dataclass(frozen=True)
class ExperimentProfile:
    profile_id: str
    model_id: str
    version: str
    artifact_digest: str
    template_digest: str
    tokenizer_config_digest: str
    max_projection_bytes: int
    max_input_tokens: int
    max_output_tokens: int
    max_context_tokens: int
    vocabulary_size: int
    max_output_bytes: int
    max_event_bytes: int
    max_request_seconds: float

    def __post_init__(self) -> None:
        for name in ("profile_id", "model_id"):
            if not isinstance(getattr(self, name), str) or not 0 < len(getattr(self, name)) <= 256:
                raise ValueError(f"invalid {name}")
        for name in ("version", "artifact_digest", "template_digest", "tokenizer_config_digest"):
            value = getattr(self, name)
            if (
                not isinstance(value, str)
                or len(value) != 64
                or any(c not in "0123456789abcdef" for c in value)
            ):
                raise ValueError(f"invalid {name}")
        for name in (
            "max_projection_bytes",
            "max_input_tokens",
            "max_output_tokens",
            "max_context_tokens",
            "vocabulary_size",
            "max_output_bytes",
            "max_event_bytes",
        ):
            positive_int(getattr(self, name), name)
        if self.max_event_bytes > self.max_output_bytes:
            raise ValueError("event bound exceeds output bound")
        if (
            type(self.max_request_seconds) not in (int, float)
            or not math.isfinite(self.max_request_seconds)
            or self.max_request_seconds <= 0
        ):
            raise ValueError("invalid request time bound")

    def binding(self, incarnation: str) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "profile_id": self.profile_id,
            "model_id": self.model_id,
            "version": self.version,
            "artifact_sha256": self.artifact_digest,
            "template_sha256": self.template_digest,
            "tokenizer_config_sha256": self.tokenizer_config_digest,
            "incarnation": incarnation,
            "enable_thinking": True,
            "reasoning_effort": "medium",
            "output_projection": "legacy_blended",
        }


@dataclass(frozen=True)
class AdmittedHistory:
    prompt_ids: tuple[int, ...]
    history_len: int
    checkpoint_boundaries: tuple[int, ...]
    deadline_monotonic: float


def _invalid(message: str) -> BackendError:
    return BackendError("invalid_history_projection", message, False)


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _invalid("duplicate projection key")
        result[key] = value
    return result


def _constant(_: str) -> None:
    raise _invalid("nonfinite projection value")


def _json(payload: bytes) -> Any:
    try:
        return json.loads(payload, object_pairs_hook=_object, parse_constant=_constant)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise _invalid("invalid projection JSON") from exc


def _request_identity(value: Any) -> None:
    if not isinstance(value, str):
        raise _invalid("invalid request identity")
    identity = value
    for prefix in ("chatcmpl-", "resp_"):
        if identity.startswith(prefix):
            identity = identity[len(prefix) :]
            break
    if len(identity) != 36:
        raise _invalid("invalid request identity")
    try:
        if str(UUID(identity)) != identity:
            raise ValueError("noncanonical UUID")
    except ValueError as exc:
        raise _invalid("invalid request identity") from exc


def admit_history(
    request: Any,
    *,
    profile: ExperimentProfile,
    incarnation: str,
    render: Callable[..., str],
    encode: Callable[[str], list[int]],
    wall_seconds: float,
    monotonic_seconds: float,
) -> AdmittedHistory:
    """Verify the unchanged history against authoritative text and token IDs.

    The caller invokes this before any Scheduler submit, cache lookup or native
    operation. No inferred or supplied structured prior reasoning is removed.
    """
    payload = getattr(request, "tensorfold_history_projection_json", b"")
    if type(payload) is not bytes or not 0 < len(payload) <= profile.max_projection_bytes:
        raise _invalid("missing or oversized trusted history projection")
    projection = _json(payload)
    expected = profile.binding(incarnation)
    if type(projection) is not dict or set(projection) != set(expected) | {"messages", "tools"}:
        raise _invalid("unsupported projection schema")
    if any(type(projection[k]) is not type(v) or projection[k] != v for k, v in expected.items()):
        raise _invalid("profile or incarnation binding mismatch")
    if (request.model_id, request.version) != (profile.model_id, profile.version):
        raise _invalid("request model binding mismatch")
    _request_identity(request.request_id)
    if getattr(request, "return_logprobs", False) or getattr(request, "return_token_ids", False):
        raise _invalid("token/logprob output is not admitted by this experiment")
    has_field = getattr(request, "HasField", None)
    if callable(has_field) and request.HasField("preparation_redemption"):
        raise _invalid("prepared reasoning redemption is not admitted by this experiment")
    if getattr(request, "cache_affinity_fingerprint", ""):
        raise _invalid("cross-profile cache affinity is unsupported")
    messages, tools = projection["messages"], projection["tools"]
    if type(messages) is not list or not messages or type(tools) is not list:
        raise _invalid("invalid canonical history")
    for message in messages:
        if (
            type(message) is not dict
            or type(message.get("role")) is not str
            or message["role"] not in {"system", "developer", "user", "assistant", "tool"}
        ):
            raise _invalid("unsupported canonical message")
        if {"reasoning", "reasoning_content", "reasoning_details", "thinking"}.intersection(
            message
        ):
            raise _invalid("structured prior reasoning is unsupported")
    params = request.params
    tools_payload = getattr(params, "tools_json", b"")
    if len(tools_payload) > profile.max_projection_bytes or _json(tools_payload or b"[]") != tools:
        raise _invalid("tool schema binding mismatch")
    tool_choice_payload = getattr(params, "tool_choice_json", b"")
    if len(tool_choice_payload) > profile.max_projection_bytes:
        raise _invalid("tool choice exceeds bounded projection")
    if _json(tool_choice_payload or b"null") is not None:
        raise _invalid("tool choice controls are not admitted by this experiment")
    if getattr(params, "stop_sequences", ()):
        raise _invalid("stop controls are not admitted by this experiment")
    limit = params.max_output_tokens
    if type(limit) is not int or not 0 < limit <= profile.max_output_tokens:
        raise _invalid("output limit exceeds frozen profile")
    for value, lower, upper in ((params.temperature, 0, 2), (params.top_p, 0, 1)):
        if (
            type(value) not in (int, float)
            or not math.isfinite(value)
            or not lower <= value <= upper
        ):
            raise _invalid("invalid sampling controls")
    remaining = request.deadline_unix_ms / 1000 - wall_seconds
    if not math.isfinite(remaining) or not 0 < remaining <= profile.max_request_seconds:
        raise _invalid("request deadline exceeds frozen profile")
    ids = tuple(request.prompt_token_ids)
    if not 0 < len(ids) <= profile.max_input_tokens or any(
        type(token) is not int or not 0 <= token < profile.vocabulary_size for token in ids
    ):
        raise _invalid("invalid authoritative token IDs")
    if request.input_tokens != len(ids) or len(ids) + limit > profile.max_context_tokens:
        raise _invalid("context or input count mismatch")
    try:
        messages = normalize_history(messages)
        text = render(messages, tools=tools, add_generation_prompt=True)
        history = render(messages, tools=tools, add_generation_prompt=False)
        rendered_ids = tuple(encode(text))
        history_ids = tuple(encode(history))
    except Exception as exc:
        raise _invalid("canonical history cannot be rendered") from exc
    if text.encode("utf-8") != request.rendered_prompt_utf8 or rendered_ids != ids:
        raise _invalid("authoritative rendered prompt mismatch")
    history_len = len(history_ids)
    if not 0 < history_len < len(ids) or ids[:history_len] != history_ids:
        raise _invalid("history does not form a verified prompt prefix")
    return AdmittedHistory(ids, history_len, (history_len,), monotonic_seconds + remaining)
