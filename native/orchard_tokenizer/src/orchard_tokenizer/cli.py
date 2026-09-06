from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Final, cast

import sentencepiece as sentencepiece
from jinja2 import Environment, TemplateError, Undefined
from jinja2 import meta as jinja_meta
from tokenizers import Tokenizer

from orchard_tokenizer import __version__
from orchard_tokenizer.catalog import extract_safe_tokenization_catalog
from orchard_tokenizer.safe_segmented import (
    MarkerPair,
    SafeSegmentedError,
    catalog_sha256,
    choose_marker_nonce,
    details_for_error,
    dual_render_guard,
    dual_render_guard_sentinel_matrix,
    encode_rendered_segments,
    event_to_dict,
    load_two_tokenizers,
    precompute_safe_ids,
    tag_caller_strings,
    walk_rendered,
)
from orchard_tokenizer.template_sandbox import ProvenanceSandbox

# Prompt-shaping tokens that must be resolved when referenced by a template.
# If a template uses {{ bos_token }} or {{ eos_token }}, the value MUST come
# from tokenizer_config.json; silent empty-string fallback corrupts the prompt.
_REQUIRED_SPECIAL_TOKENS: Final[frozenset[str]] = frozenset({"bos_token", "eos_token"})
_SUPPORTED_MESSAGE_ROLES: Final[frozenset[str]] = frozenset(
    {"system", "developer", "user", "assistant", "tool"}
)

# All special-token keys we attempt to extract from tokenizer_config.json.
_EXTRACTABLE_SPECIAL_TOKENS: Final[frozenset[str]] = frozenset(
    {
        "bos_token",
        "eos_token",
        "pad_token",
        "unk_token",
    }
)

CONTRACT_VERSION: Final[int] = 3
SUPPORTED_CONTRACT_VERSIONS: Final[frozenset[int]] = frozenset({1, 2, CONTRACT_VERSION})
HF_TOKENIZER_KINDS: Final[set[str]] = {"huggingface_tokenizer_json", "tokenizer_json"}
SENTENCEPIECE_KINDS: Final[set[str]] = {
    "sentencepiece_model",
    "sentencepiece_tokenizer_model",
}
_SKIP_SENTINEL_PREFLIGHT_ENV: Final[str] = "ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT"
_DETERMINISTIC_PREFLIGHT_INCOMPATIBILITIES: Final[frozenset[str]] = frozenset(
    {
        "per_codepoint_decode_mismatch",
        "reserved_id_persists",
        "reserved_id_set_overlap",
        "empty_literal",
        "dual_render_mismatch",
    }
)


@dataclass(slots=True)
class TokenizerCliError(Exception):
    category: str
    message: str
    exit_code: int
    details: dict[str, Any] | None = None

    def __str__(self) -> str:
        return self.message


class TemplateRequestError(TemplateError):
    """Raised when a chat template intentionally rejects a request."""


def build_success_response(
    rendered_prompt: str,
    input_token_count: int,
    *,
    contract_version: int = CONTRACT_VERSION,
) -> dict[str, Any]:
    return build_success_result_response(
        {
            "rendered_prompt": rendered_prompt,
            "input_token_count": input_token_count,
        },
        contract_version=contract_version,
    )


def build_success_result_response(
    result: dict[str, Any],
    *,
    contract_version: int = CONTRACT_VERSION,
) -> dict[str, Any]:
    return {
        "contract_version": contract_version,
        "ok": True,
        "result": result,
    }


def build_error_response(
    category: str,
    message: str,
    *,
    contract_version: int = CONTRACT_VERSION,
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    error: dict[str, Any] = {
        "category": category,
        "message": message,
    }
    if details:
        error["details"] = details

    return {
        "contract_version": contract_version,
        "ok": False,
        "error": error,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="orchard-tokenizer",
        description="Orchard exact prompt rendering and token counting helper.",
    )
    parser.add_argument("--request-json", help="structured tokenization request payload")
    parser.add_argument("--version", action="store_true", help="print the package version and exit")
    args = parser.parse_args(argv)

    if args.version:
        print(__version__)
        return 0

    response_contract_version = CONTRACT_VERSION

    try:
        payload = load_payload(args.request_json)
        response_contract_version = response_version_for_payload(payload)
        result = execute_contract(payload)
        response_contract_version = int(result.pop("contract_version"))
        print(
            json.dumps(
                build_success_result_response(
                    result,
                    contract_version=response_contract_version,
                ),
                ensure_ascii=False,
            )
        )
        return 0
    except TokenizerCliError as exc:
        print(
            json.dumps(
                build_error_response(
                    exc.category,
                    exc.message,
                    contract_version=response_contract_version,
                    details=exc.details,
                ),
                ensure_ascii=False,
            )
        )
        return exc.exit_code
    except Exception:
        print(
            json.dumps(
                build_error_response(
                    "internal_error",
                    "unexpected tokenizer failure",
                    contract_version=response_contract_version,
                ),
                ensure_ascii=False,
            )
        )
        return 1


def load_payload(request_json: str | None) -> dict[str, Any]:
    payload_text = request_json if request_json is not None else sys.stdin.read()

    if payload_text.strip() == "":
        raise TokenizerCliError("invalid_input", "request JSON is required", 2)

    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError as exc:
        raise TokenizerCliError("invalid_input", f"request JSON is invalid: {exc.msg}", 2) from exc

    if not isinstance(payload, dict):
        raise TokenizerCliError("invalid_input", "request JSON must decode to an object", 2)

    return payload


def response_version_for_payload(payload: dict[str, Any]) -> int:
    contract_version = payload.get("contract_version")

    if contract_version in SUPPORTED_CONTRACT_VERSIONS:
        return int(contract_version)

    return CONTRACT_VERSION


def execute_contract(payload: dict[str, Any]) -> dict[str, Any]:
    contract_version = payload.get("contract_version")
    command = payload.get("command")

    if contract_version not in SUPPORTED_CONTRACT_VERSIONS:
        raise TokenizerCliError(
            "invalid_input",
            f"unsupported contract_version: {contract_version!r}",
            2,
        )

    if command == "render_and_count":
        return _execute_render_and_count(payload, int(contract_version))

    if command == "render_and_count_segmented":
        if int(contract_version) != CONTRACT_VERSION:
            raise TokenizerCliError(
                "invalid_input",
                "render_and_count_segmented requires contract_version 3",
                2,
            )

        try:
            return {
                "contract_version": int(contract_version),
                **_execute_render_and_count_segmented(payload),
            }
        except SafeSegmentedError as exc:
            raise TokenizerCliError(
                exc.category,
                str(exc),
                2,
                details_for_error(exc),
            ) from exc
        except FileNotFoundError as exc:
            raise TokenizerCliError("missing_assets", str(exc), 3) from exc
        except OSError as exc:
            raise TokenizerCliError("missing_assets", str(exc), 3) from exc

    if command == "extract_safe_tokenization_catalog":
        if int(contract_version) != CONTRACT_VERSION:
            raise TokenizerCliError(
                "invalid_input",
                "extract_safe_tokenization_catalog requires contract_version 3",
                2,
            )

        try:
            return {
                "contract_version": int(contract_version),
                **extract_safe_tokenization_catalog(payload),
            }
        except ValueError as exc:
            raise TokenizerCliError("invalid_input", str(exc), 2) from exc
        except FileNotFoundError as exc:
            raise TokenizerCliError("missing_assets", str(exc), 3) from exc

    if command == "preflight_safe_tokenization":
        if int(contract_version) != CONTRACT_VERSION:
            raise TokenizerCliError(
                "invalid_input",
                "preflight_safe_tokenization requires contract_version 3",
                2,
            )

        try:
            return {
                "contract_version": int(contract_version),
                **_execute_preflight_safe_tokenization(payload),
            }
        except SafeSegmentedError as exc:
            reason = exc.reason if isinstance(exc.reason, dict) else {}
            category = reason.get("category")
            if category in _DETERMINISTIC_PREFLIGHT_INCOMPATIBILITIES:
                return {
                    "contract_version": int(contract_version),
                    "compatible": False,
                    "template_compatible": category != "dual_render_mismatch",
                    "incompatibility_reason": reason,
                }

            raise TokenizerCliError(
                exc.category,
                str(exc),
                2,
                details_for_error(exc),
            ) from exc
        except FileNotFoundError as exc:
            raise TokenizerCliError("missing_assets", str(exc), 3) from exc
        except OSError as exc:
            raise TokenizerCliError("missing_assets", str(exc), 3) from exc

    raise TokenizerCliError("invalid_input", f"unsupported command: {command!r}", 2)


def _execute_render_and_count(payload: dict[str, Any], contract_version: int) -> dict[str, Any]:
    assets = require_mapping(payload, "assets")
    request = require_mapping(payload, "request")

    tokenizer_kind = require_non_empty_string(assets, "tokenizer_kind", category="invalid_input")
    tokenizer_path = Path(
        require_non_empty_string(assets, "tokenizer_path", category="missing_assets")
    )
    chat_template_path = Path(
        require_non_empty_string(assets, "chat_template_path", category="missing_assets")
    )

    messages = normalize_messages(request)
    tools = normalize_optional_tools(request.get("tools"))
    tool_choice = request.get("tool_choice", None)
    prompt_lines = [f"{message['role']} {message['content']}" for message in messages]
    tokenizer_config_path = tokenizer_path.parent / "tokenizer_config.json"
    rendered_prompt = render_prompt(
        messages,
        prompt_lines,
        chat_template_path,
        tokenizer_config_path,
        tools=tools,
        tool_choice=tool_choice,
    )
    input_token_count = count_tokens(rendered_prompt, tokenizer_kind, tokenizer_path)

    return {
        "contract_version": contract_version,
        "rendered_prompt": rendered_prompt,
        "input_token_count": input_token_count,
    }


def _execute_preflight_safe_tokenization(payload: dict[str, Any]) -> dict[str, Any]:
    assets = require_mapping(payload, "assets")

    tokenizer_kind = require_non_empty_string(assets, "tokenizer_kind", category="invalid_input")
    if tokenizer_kind not in HF_TOKENIZER_KINDS:
        raise TokenizerCliError(
            "unsupported_tokenizer",
            f"preflight_safe_tokenization requires a HuggingFace tokenizer, got: {tokenizer_kind}",
            4,
        )

    tokenizer_path = Path(
        require_non_empty_string(assets, "tokenizer_path", category="missing_assets")
    )
    tokenizer_config_path = Path(
        require_non_empty_string(assets, "tokenizer_config_path", category="missing_assets")
    )
    chat_template_path = Path(
        require_non_empty_string(assets, "chat_template_path", category="missing_assets")
    )

    if not tokenizer_config_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer config asset is missing: {tokenizer_config_path}",
            3,
        )

    control_tokens, expected_catalog_sha256 = _require_safe_tokenization_catalog(payload)
    actual_catalog_sha256 = catalog_sha256(control_tokens)
    if actual_catalog_sha256 != expected_catalog_sha256:
        raise SafeSegmentedError(
            "safe_tokenization_catalog_hash_mismatch",
            "safe tokenization catalog hash does not match control_tokens",
            reason={
                "category": "catalog_hash_mismatch",
                "expected": expected_catalog_sha256,
                "actual": actual_catalog_sha256,
            },
        )

    try:
        tokenizer_template, tokenizer_safe = load_two_tokenizers(tokenizer_path)
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc

    precompute_safe_ids(control_tokens, tokenizer_template, tokenizer_safe)
    _run_template_sentinel_preflight(
        control_tokens,
        chat_template_path,
        tokenizer_config_path,
    )

    return {
        "compatible": True,
        "template_compatible": True,
        "incompatibility_reason": None,
    }


def _execute_render_and_count_segmented(payload: dict[str, Any]) -> dict[str, Any]:
    assets = require_mapping(payload, "assets")
    request = normalize_tool_history(require_mapping(payload, "request"))

    tokenizer_kind = require_non_empty_string(assets, "tokenizer_kind", category="invalid_input")
    if tokenizer_kind not in HF_TOKENIZER_KINDS:
        raise TokenizerCliError(
            "unsupported_tokenizer",
            f"render_and_count_segmented requires a HuggingFace tokenizer, got: {tokenizer_kind}",
            4,
        )

    tokenizer_path = Path(
        require_non_empty_string(assets, "tokenizer_path", category="missing_assets")
    )
    tokenizer_config_path = Path(
        require_non_empty_string(assets, "tokenizer_config_path", category="missing_assets")
    )
    chat_template_path = Path(
        require_non_empty_string(assets, "chat_template_path", category="missing_assets")
    )

    if not tokenizer_config_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer config asset is missing: {tokenizer_config_path}",
            3,
        )

    control_tokens, expected_catalog_sha256 = _require_safe_tokenization_catalog(payload)
    actual_catalog_sha256 = catalog_sha256(control_tokens)
    if actual_catalog_sha256 != expected_catalog_sha256:
        raise SafeSegmentedError(
            "safe_tokenization_catalog_hash_mismatch",
            "safe tokenization catalog hash does not match control_tokens",
            reason={
                "category": "catalog_hash_mismatch",
                "expected": expected_catalog_sha256,
                "actual": actual_catalog_sha256,
            },
        )

    if os.environ.get(_SKIP_SENTINEL_PREFLIGHT_ENV) != "1":
        _run_template_sentinel_preflight(
            control_tokens,
            chat_template_path,
            tokenizer_config_path,
        )

    messages = normalize_messages_preserving_message_fields(request)
    tools = normalize_optional_tools(request.get("tools"))
    tool_choice = request.get("tool_choice", None)
    input_items = messages

    prompt_lines = [f"{message['role']} {message['content']}" for message in messages]
    paired_render_time = datetime.now()
    baseline_render = render_prompt(
        messages,
        prompt_lines,
        chat_template_path,
        tokenizer_config_path,
        tools=tools,
        tool_choice=tool_choice,
        render_time=paired_render_time,
    )

    nonce = choose_marker_nonce(input_items, tools, tool_choice)
    tagged_payload, marker_pairs = tag_caller_strings(input_items, tools, tool_choice, nonce)
    tagged_request = {"input_items": tagged_payload["input_items"]}
    tagged_messages = normalize_messages_preserving_message_fields(tagged_request)
    tagged_tools = normalize_optional_tools(tagged_payload["tools"])
    tagged_tool_choice = tagged_payload["tool_choice"]
    tagged_prompt_lines = [f"{message['role']} {message['content']}" for message in tagged_messages]
    tagged_render = render_prompt(
        tagged_messages,
        tagged_prompt_lines,
        chat_template_path,
        tokenizer_config_path,
        tools=tagged_tools,
        tool_choice=tagged_tool_choice,
        render_time=paired_render_time,
        marker_pairs=marker_pairs,
    )
    dual_render_guard(baseline_render, tagged_render, marker_pairs)

    try:
        tokenizer_template, tokenizer_safe = load_two_tokenizers(tokenizer_path)
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc

    safe_ids_result = precompute_safe_ids(control_tokens, tokenizer_template, tokenizer_safe)
    segments = walk_rendered(tagged_render, marker_pairs)
    rendered_prompt, prompt_token_ids, events = encode_rendered_segments(
        segments,
        control_tokens,
        safe_ids_result.safe_ids,
        tokenizer_template,
        tokenizer_safe,
    )

    decoded_prompt = tokenizer_template.decode(prompt_token_ids, skip_special_tokens=False)
    if decoded_prompt != rendered_prompt:
        raise SafeSegmentedError(
            "safe_tokenization_incompatible_tokenizer",
            "segmented token IDs do not decode to the rendered prompt",
            reason={
                "category": "per_codepoint_decode_mismatch",
                "first_diff_offset": _first_diff_offset(decoded_prompt, rendered_prompt),
            },
        )

    return {
        "rendered_prompt": rendered_prompt,
        "input_token_count": len(prompt_token_ids),
        "prompt_token_ids": prompt_token_ids,
        "compatible": True,
        "template_compatible": True,
        "incompatibility_reason": None,
        "safe_encoding_events": [event_to_dict(event) for event in events],
    }


def _run_template_sentinel_preflight(
    control_tokens: list[str],
    chat_template_path: Path,
    tokenizer_config_path: Path,
) -> None:
    preflight_render_time = datetime.now()

    def render_payload(payload: dict[str, Any], marker_pairs: Sequence[MarkerPair] = ()) -> str:
        request = {"input_items": payload["input_items"]}
        messages = normalize_messages_preserving_message_fields(request)
        tools = normalize_optional_tools(payload.get("tools"))
        tool_choice = payload.get("tool_choice", None)
        prompt_lines = [f"{message['role']} {message['content']}" for message in messages]
        return render_prompt(
            messages,
            prompt_lines,
            chat_template_path,
            tokenizer_config_path,
            tools=tools,
            tool_choice=tool_choice,
            render_time=preflight_render_time,
            marker_pairs=marker_pairs,
        )

    dual_render_guard_sentinel_matrix(
        control_tokens, render_payload, render_tagged_payload=render_payload
    )


def _require_safe_tokenization_catalog(payload: dict[str, Any]) -> tuple[list[str], str]:
    safe_tokenization = require_mapping(payload, "safe_tokenization")
    control_tokens = safe_tokenization.get("control_tokens")
    catalog_hash = safe_tokenization.get("catalog_sha256")

    if not isinstance(control_tokens, list) or not all(
        isinstance(token, str) for token in control_tokens
    ):
        raise TokenizerCliError(
            "invalid_input",
            "safe_tokenization.control_tokens must be an array of strings",
            2,
        )

    if not isinstance(catalog_hash, str) or catalog_hash == "":
        raise TokenizerCliError(
            "invalid_input",
            "safe_tokenization.catalog_sha256 must be a non-empty string",
            2,
        )

    return cast(list[str], control_tokens), catalog_hash


def _first_diff_offset(left: str, right: str) -> int:
    for index, (left_char, right_char) in enumerate(zip(left, right, strict=False)):
        if left_char != right_char:
            return index
    return min(len(left), len(right))


def require_mapping(payload: dict[str, Any], field_name: str) -> dict[str, Any]:
    value = payload.get(field_name)

    if isinstance(value, dict):
        return value

    raise TokenizerCliError(
        "invalid_input",
        f"{field_name} must be an object, got: {value!r}",
        2,
    )


def require_non_empty_string(payload: dict[str, Any], field_name: str, *, category: str) -> str:
    value = payload.get(field_name)

    if isinstance(value, str) and value != "":
        return value

    raise TokenizerCliError(
        category,
        f"{field_name} must be a non-empty string",
        3 if category == "missing_assets" else 2,
    )


def _validate_message_role(role: Any, index: int) -> str:
    if not isinstance(role, str) or role == "":
        raise TokenizerCliError(
            "invalid_input",
            f"request.input_items[{index}].role must be a non-empty string",
            2,
        )

    if role not in _SUPPORTED_MESSAGE_ROLES:
        raise TokenizerCliError(
            "invalid_input",
            f"request.input_items[{index}].role is unsupported: {role!r}",
            2,
        )

    return role


def normalize_messages(request: dict[str, Any]) -> list[dict[str, str]]:
    input_items = request.get("input_items")

    if not isinstance(input_items, list):
        raise TokenizerCliError(
            "invalid_input",
            f"request.input_items must be a list, got: {input_items!r}",
            2,
        )

    messages: list[dict[str, str]] = []

    for index, item in enumerate(input_items):
        if not isinstance(item, dict):
            raise TokenizerCliError(
                "invalid_input",
                f"request.input_items[{index}] must be an object, got: {item!r}",
                2,
            )

        item_map = cast(dict[str, Any], item)
        role = _validate_message_role(item_map.get("role"), index)

        messages.append(
            {"role": role, "content": normalize_content(item_map.get("content"), index)}
        )

    return messages


def normalize_tool_history(request: dict[str, Any]) -> dict[str, Any]:
    """Decode API history arguments before rendering or tagging caller strings."""
    normalized = deepcopy(request)
    items = normalized.get("input_items")
    if not isinstance(items, list):
        return normalized
    for item in items:
        if not isinstance(item, dict):
            continue
        calls = item.get("tool_calls")
        if not isinstance(calls, list):
            continue
        for call in calls:
            if not isinstance(call, dict) or not isinstance(call.get("function"), dict):
                continue
            function = call["function"]
            if "arguments" not in function:
                continue
            arguments = function["arguments"]
            try:
                if isinstance(arguments, str):
                    arguments = json.loads(arguments, object_pairs_hook=_unique_argument_keys)
                if not isinstance(arguments, dict):
                    raise ValueError("arguments must be an object")
                json.dumps(arguments, allow_nan=False)
            except (ValueError, TypeError, RecursionError) as exc:
                raise TokenizerCliError(
                    "invalid_input", "tool history arguments must be a valid JSON object", 2
                ) from exc
            function["arguments"] = arguments
        if item.get("role") == "assistant" and item.get("content") is None:
            if not calls or not all(_valid_history_function_call(call) for call in calls):
                raise TokenizerCliError(
                    "invalid_input", "absent assistant content requires valid function calls", 2
                )
            item["content"] = ""
    return normalized


def _valid_history_function_call(call: Any) -> bool:
    if not isinstance(call, dict) or call.get("type", "function") != "function":
        return False
    function = call.get("function")
    return (
        isinstance(call.get("id"), str)
        and bool(call["id"])
        and isinstance(function, dict)
        and isinstance(function.get("name"), str)
        and bool(function["name"])
        and isinstance(function.get("arguments"), dict)
    )


def _unique_argument_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate argument key")
        result[key] = value
    return result


def normalize_messages_preserving_message_fields(request: dict[str, Any]) -> list[dict[str, Any]]:
    input_items = request.get("input_items")

    if not isinstance(input_items, list):
        raise TokenizerCliError(
            "invalid_input",
            f"request.input_items must be a list, got: {input_items!r}",
            2,
        )

    messages: list[dict[str, Any]] = []
    for index, item in enumerate(input_items):
        if not isinstance(item, dict):
            raise TokenizerCliError(
                "invalid_input",
                f"request.input_items[{index}] must be an object, got: {item!r}",
                2,
            )

        item_map = cast(dict[str, Any], item)
        role = _validate_message_role(item_map.get("role"), index)

        message = item_map.copy()
        message["role"] = role
        message["content"] = normalize_content(item_map.get("content"), index)
        messages.append(message)

    return messages


def normalize_optional_tools(tools: Any) -> list[dict[str, Any]] | None:
    if tools is None:
        return None

    normalized_tools = normalize_tools(tools)
    if normalized_tools == []:
        return None

    return normalized_tools


def normalize_tools(tools: Any) -> list[dict[str, Any]]:
    if not isinstance(tools, list):
        raise TokenizerCliError(
            "invalid_input",
            f"request.tools must be an array, got: {tools!r}",
            2,
        )

    for index, tool in enumerate(tools):
        if not isinstance(tool, dict):
            raise TokenizerCliError(
                "invalid_input",
                f"request.tools[{index}] must be an object, got: {tool!r}",
                2,
            )

    return tools


def normalize_content(content: Any, item_index: int) -> str:
    if isinstance(content, str):
        return content

    if isinstance(content, list):
        parts: list[str] = []

        for part_index, part in enumerate(content):
            if not isinstance(part, dict):
                raise TokenizerCliError(
                    "invalid_input",
                    f"request.input_items[{item_index}].content[{part_index}] must be an object",
                    2,
                )

            part_map = cast(dict[str, Any], part)
            part_type = part_map.get("type")
            text = part_map.get("text")

            if part_type != "text" or not isinstance(text, str):
                raise TokenizerCliError(
                    "invalid_input",
                    f"request.input_items[{item_index}].content[{part_index}] must be a text part",
                    2,
                )

            parts.append(text)

        return "".join(parts)

    raise TokenizerCliError(
        "invalid_input",
        f"request.input_items[{item_index}].content must be a string or text-part list",
        2,
    )


def _raise_exception(message: str) -> None:
    raise TemplateRequestError(message)


def _chat_template_environment(
    render_time: datetime | None = None, marker_pairs: Sequence[MarkerPair] = ()
) -> Environment:
    render_time = render_time or datetime.now()

    def strftime_now(format_string: str) -> str:
        return render_time.strftime(format_string)

    environment = ProvenanceSandbox(
        autoescape=False,
        lstrip_blocks=True,
        trim_blocks=True,
        undefined=Undefined,
        marker_pairs=marker_pairs,
    )
    filters_map = cast(dict[str, Any], environment.filters)
    filters_map["length"] = _length_filter
    filters_map["count"] = _length_filter
    environment.guard_filters()
    globals_map = cast(dict[str, Any], environment.globals)
    globals_map["raise_exception"] = _raise_exception
    globals_map["strftime_now"] = strftime_now
    return environment


def _length_filter(value: Any) -> int:
    if value is None:
        return 0

    return len(value)


def render_prompt(
    messages: list[dict[str, Any]],
    prompt_lines: list[str],
    chat_template_path: Path,
    tokenizer_config_path: Path | None = None,
    *,
    tools: list[dict[str, Any]] | None = None,
    tool_choice: Any = None,
    render_time: datetime | None = None,
    marker_pairs: Sequence[MarkerPair] = (),
) -> str:
    if not chat_template_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"chat template asset is missing: {chat_template_path}",
            3,
        )

    try:
        template_text = chat_template_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"failed to read chat template asset: {chat_template_path}",
            3,
        ) from exc

    environment = _chat_template_environment(render_time, marker_pairs)

    # Discover which variables the template references via AST introspection.
    referenced_vars = _discover_template_variables(template_text, environment)

    # Determine which prompt-shaping tokens this template requires.
    required_tokens = frozenset(referenced_vars & _REQUIRED_SPECIAL_TOKENS)

    # Load special tokens — strict when required tokens are referenced,
    # best-effort otherwise.
    special_tokens = _load_special_tokens(tokenizer_config_path, required=required_tokens)

    # Fail deterministically if any required prompt-shaping token is unresolved.
    _ensure_required_tokens(required_tokens, special_tokens)

    try:
        template = environment.from_string(template_text)
        return template.render(
            messages=messages,
            prompt_lines=prompt_lines,
            add_generation_prompt=True,
            tools=tools,
            tool_choice=tool_choice,
            **special_tokens,
        )
    except TemplateRequestError as exc:
        raise TokenizerCliError(
            "invalid_input",
            f"chat template rejected request: {exc}",
            2,
        ) from exc
    except TemplateError as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"chat template asset is invalid: {exc}",
            3,
        ) from exc


def _discover_template_variables(template_text: str, environment: Environment) -> set[str]:
    """Return undeclared variable names referenced by a Jinja template."""
    try:
        ast = environment.parse(template_text)
        return jinja_meta.find_undeclared_variables(ast)
    except TemplateError:
        # Let the main render call produce the user-facing error.
        return set()


def _load_special_tokens(
    tokenizer_config_path: Path | None,
    *,
    required: frozenset[str],
) -> dict[str, str]:
    """Extract special-token values from tokenizer_config.json.

    When *required* is non-empty AND the config file is missing/unreadable,
    raises a deterministic ``TokenizerCliError``.  When *required* is empty,
    failures are silently tolerated (best-effort extraction).
    """
    if tokenizer_config_path is None or not tokenizer_config_path.is_file():
        if required:
            raise TokenizerCliError(
                "missing_assets",
                f"chat template requires special tokens {sorted(required)} "
                f"but tokenizer_config.json is missing at {tokenizer_config_path}",
                3,
            )
        return {}

    try:
        tc = json.loads(tokenizer_config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        if required:
            raise TokenizerCliError(
                "missing_assets",
                f"chat template requires special tokens {sorted(required)} "
                f"but tokenizer_config.json could not be read: {exc}",
                3,
            ) from exc
        return {}

    tokens: dict[str, str] = {}
    for key in _EXTRACTABLE_SPECIAL_TOKENS:
        val = tc.get(key)
        if isinstance(val, str) and val:
            tokens[key] = val
        elif isinstance(val, dict):
            content = val.get("content", "")
            if isinstance(content, str) and content:
                tokens[key] = content
    return tokens


def _ensure_required_tokens(
    required: frozenset[str],
    resolved: dict[str, str],
) -> None:
    """Raise if any required prompt-shaping token is unresolved."""
    missing = sorted(required - resolved.keys())
    if missing:
        raise TokenizerCliError(
            "missing_assets",
            f"chat template requires unresolved special tokens: {', '.join(missing)}",
            3,
        )


def count_tokens(rendered_prompt: str, tokenizer_kind: str, tokenizer_path: Path) -> int:
    if not tokenizer_path.is_file():
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is missing: {tokenizer_path}",
            3,
        )

    if tokenizer_kind in HF_TOKENIZER_KINDS:
        return count_huggingface_tokens(rendered_prompt, tokenizer_path)

    if tokenizer_kind in SENTENCEPIECE_KINDS:
        return count_sentencepiece_tokens(rendered_prompt, tokenizer_path)

    raise TokenizerCliError(
        "unsupported_tokenizer",
        f"unsupported tokenizer_kind: {tokenizer_kind}",
        4,
    )


def count_huggingface_tokens(rendered_prompt: str, tokenizer_path: Path) -> int:
    try:
        tokenizer = Tokenizer.from_file(str(tokenizer_path))
        return len(tokenizer.encode(rendered_prompt).ids)
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc


def count_sentencepiece_tokens(rendered_prompt: str, tokenizer_path: Path) -> int:
    try:
        processor = sentencepiece.SentencePieceProcessor()
        processor.Load(str(tokenizer_path))
        return len(processor.EncodeAsIds(rendered_prompt))
    except Exception as exc:
        raise TokenizerCliError(
            "missing_assets",
            f"tokenizer asset is invalid: {tokenizer_path}",
            3,
        ) from exc


if __name__ == "__main__":
    raise SystemExit(main())
