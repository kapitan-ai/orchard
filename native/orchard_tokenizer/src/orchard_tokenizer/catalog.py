"""Safe-tokenization catalog helpers for orchard_tokenizer.

This module owns only source #4 (chat-template literals) and source #5
(wrapper tool markers) for Phase 1 manifest catalog extraction.

Wrapper marker values are maintained as a static lookup table sourced from
upstream ``mlx_lm.tool_parsers.*`` modules. When
``native/orchard_worker_mlx`` updates its ``mlx-lm`` dependency, refresh this
mapping against the installed tool parser modules and update tests.

An optional sync test may import ``mlx_lm.tool_parsers`` only when that
package is available. ``orchard_tokenizer`` intentionally has no direct
``mlx-lm`` dependency.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jinja2 import Environment, TemplateError, nodes

_CONTROL_LITERAL_PATTERN = re.compile(
    r"""
    <\|[^<>]*\|>
    |</?[A-Za-z][A-Za-z0-9_:\-]*(?:\s+[^<>]*)?\s*/?>
    |\[/?[A-Z][A-Z0-9_:\-]*\]
    """,
    re.VERBOSE,
)

_WRAPPER_TOOL_MARKERS: dict[str, tuple[str, str]] = {
    "qwen2": ("<tool_call>", "</tool_call>"),
    "hermes": ("<tool_call>", "</tool_call>"),
    "llama_31": ("<tool_call>", "</tool_call>"),
    "json_tools": ("<tool_call>", "</tool_call>"),
    "function_gemma": ("<start_function_call>", "<end_function_call>"),
    "glm47": ("<tool_call>", "</tool_call>"),
    "kimi_k2": ("<|tool_calls_section_begin|>", "<|tool_calls_section_end|>"),
    "longcat": ("<longcat_tool_call>", "</longcat_tool_call>"),
    "minimax_m2": ("<minimax:tool_call>", "</minimax:tool_call>"),
    "mistral": ("[TOOL_CALLS]", ""),
    "pythonic": ("<|tool_call_start|>", "<|tool_call_end|>"),
}


def _sorted_unique_utf8(items: list[str]) -> list[str]:
    return sorted(set(items), key=lambda item: item.encode("utf-8"))


def _chat_template_from_config_entry(entry: Any) -> str | None:
    if isinstance(entry, str) and entry != "":
        return entry

    if isinstance(entry, dict):
        template = entry.get("template")
        if isinstance(template, str) and template != "":
            return template

    return None


def _chat_template_from_config_value(chat_template: Any) -> str | None:
    if isinstance(chat_template, str):
        return chat_template if chat_template != "" else None

    if isinstance(chat_template, list):
        default_entry = next(
            (
                entry
                for entry in chat_template
                if isinstance(entry, dict) and entry.get("name") == "default"
            ),
            None,
        )
        if default_entry is not None:
            return _chat_template_from_config_entry(default_entry)

        if not chat_template:
            return None

        return _chat_template_from_config_entry(chat_template[0])

    return None


def _load_chat_template(
    tokenizer_config_path: Path | None,
    chat_template_path: Path | None,
) -> str | None:
    if chat_template_path is not None:
        try:
            return chat_template_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise FileNotFoundError(
                f"chat template asset is missing: {chat_template_path}"
            ) from exc

    if tokenizer_config_path is None:
        return None

    try:
        tokenizer_config = json.loads(tokenizer_config_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise FileNotFoundError(
            f"tokenizer config asset is missing: {tokenizer_config_path}"
        ) from exc
    except json.JSONDecodeError as exc:
        raise ValueError("tokenizer_config_path must contain valid JSON") from exc

    if not isinstance(tokenizer_config, dict):
        raise ValueError("tokenizer_config_path must decode to an object")

    return _chat_template_from_config_value(tokenizer_config.get("chat_template"))


def _rendered_output_string_constants(expr: nodes.Expr) -> list[str]:
    if isinstance(expr, nodes.Const) and isinstance(expr.value, str):
        return [expr.value]

    if isinstance(expr, nodes.Concat):
        values: list[str] = []
        for node in expr.nodes:
            values.extend(_rendered_output_string_constants(node))
        return values

    return []


def _extract_chat_template_literal_observations(
    tokenizer_config_path: Path | None,
    chat_template_path: Path | None = None,
) -> list[str]:
    template_text = _load_chat_template(tokenizer_config_path, chat_template_path)
    if template_text is None:
        return []

    environment = Environment(autoescape=False, lstrip_blocks=True, trim_blocks=True)
    literal_runs: list[str] = []
    current_run: list[str] = []

    try:
        for _, token_type, value in environment.lex(template_text):
            if token_type == "data":
                current_run.append(value)
                continue

            if current_run:
                literal_runs.append("".join(current_run))
                current_run = []

        ast = environment.parse(template_text)
    except TemplateError as exc:
        raise ValueError(f"chat template asset is invalid: {exc}") from exc

    if current_run:
        literal_runs.append("".join(current_run))

    matches: list[str] = []
    for run in literal_runs:
        matches.extend(match.group(0) for match in _CONTROL_LITERAL_PATTERN.finditer(run))

    for output_node in ast.find_all(nodes.Output):
        for expr in output_node.nodes:
            for value in _rendered_output_string_constants(expr):
                matches.extend(match.group(0) for match in _CONTROL_LITERAL_PATTERN.finditer(value))

    return matches


def extract_chat_template_literals(
    tokenizer_config_path: Path | None,
    chat_template_path: Path | None = None,
) -> list[str]:
    return _sorted_unique_utf8(
        _extract_chat_template_literal_observations(tokenizer_config_path, chat_template_path)
    )


def _extract_wrapper_tool_marker_observations(tool_parser_type: str | None) -> list[str]:
    if tool_parser_type is None:
        return []

    marker_pair = _WRAPPER_TOOL_MARKERS.get(tool_parser_type)
    if marker_pair is None:
        return []

    return [marker for marker in marker_pair if marker != ""]


def extract_wrapper_tool_markers(tool_parser_type: str | None) -> list[str]:
    return _sorted_unique_utf8(_extract_wrapper_tool_marker_observations(tool_parser_type))


def extract_safe_tokenization_catalog(request: dict[str, Any]) -> dict[str, Any]:
    assets = request.get("assets")
    if not isinstance(assets, dict):
        raise ValueError("assets must be an object")

    tokenizer_config_path_value = assets.get("tokenizer_config_path")
    tokenizer_config_path: Path | None = None
    if tokenizer_config_path_value is not None:
        if not isinstance(tokenizer_config_path_value, str) or tokenizer_config_path_value == "":
            raise ValueError(
                "assets.tokenizer_config_path must be a non-empty string when provided"
            )
        tokenizer_config_path = Path(tokenizer_config_path_value)

    chat_template_path_value = assets.get("chat_template_path")
    chat_template_path: Path | None = None
    if chat_template_path_value is not None:
        if not isinstance(chat_template_path_value, str) or chat_template_path_value == "":
            raise ValueError("assets.chat_template_path must be a non-empty string when provided")
        chat_template_path = Path(chat_template_path_value)

    if tokenizer_config_path is None and chat_template_path is None:
        raise ValueError("assets must include tokenizer_config_path or chat_template_path")

    options = request.get("options", {})
    if not isinstance(options, dict):
        raise ValueError("options must be an object")

    tool_parser_type_value = options.get("tool_parser_type")
    if tool_parser_type_value is not None and not isinstance(tool_parser_type_value, str):
        raise ValueError("options.tool_parser_type must be a string or null")

    chat_template_observations = _extract_chat_template_literal_observations(
        tokenizer_config_path,
        chat_template_path,
    )
    wrapper_tool_observations = _extract_wrapper_tool_marker_observations(tool_parser_type_value)

    return {
        "control_tokens_chat_template": _sorted_unique_utf8(chat_template_observations),
        "control_tokens_wrapper_tool": _sorted_unique_utf8(wrapper_tool_observations),
        "chat_template_literals_count": len(chat_template_observations),
        "wrapper_tool_markers_count": len(wrapper_tool_observations),
    }
