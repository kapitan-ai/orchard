from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from orchard_worker_mlx.backends import BackendError


@dataclass(slots=True)
class ToolCallingContext:
    tools: list[dict[str, Any]]
    parser_type: str
    tool_choice: str | dict[str, Any] | None
    tool_call_start: str
    tool_call_end: str
    tool_parser: Any
    named_tool_name: str | None = None
    requires_tool_call: bool = False
    in_tool_call: bool = False
    saw_tool_call: bool = False
    current_tool_text: str = ""
    next_tool_index: int = 0
    pending_events: list[dict[str, Any]] = field(default_factory=list)
    pending_error: BackendError | None = None
    text_buffer: str = ""
    tool_end_buffer: str = ""
    active_tool_call_id: str | None = None
    active_tool_index: int | None = None
    active_tool_name: str | None = None
    active_type_emitted: bool = False
    active_name_emitted: bool = False

    @property
    def stop_buffer_disabled(self) -> bool:
        return self.in_tool_call or self.saw_tool_call

    def take_pending_events(self) -> list[dict[str, Any]]:
        events = self.pending_events[:]
        self.pending_events.clear()
        return events


def build_context(session: Any, params: Any) -> ToolCallingContext | None:
    tools = _decode_tools_json(getattr(params, "tools_json", None) if params else None)
    tool_choice = _decode_tool_choice_json(
        getattr(params, "tool_choice_json", None) if params else None,
    )
    normalized_choice, named_tool_name, requires_tool_call = _normalize_tool_choice(tool_choice)

    if not tools:
        if requires_tool_call:
            raise BackendError(
                "invalid_generation_params",
                "tool_choice requires at least one tool definition",
                False,
            )
        return None

    if normalized_choice == "none":
        return None

    tool_calling = getattr(session, "tool_calling", {}) or {}
    supported = bool(tool_calling.get("supported"))
    parser_type = tool_calling.get("parser_type")
    tokenizer = getattr(session, "tokenizer", None)
    tool_parser = getattr(tokenizer, "tool_parser", None)
    tool_call_start = getattr(tokenizer, "tool_call_start", None)
    tool_call_end = getattr(tokenizer, "tool_call_end", "") or ""

    if not supported or not callable(tool_parser):
        raise BackendError(
            "tooling_not_supported",
            "model tokenizer does not advertise tool-calling support",
            False,
        )
    if not isinstance(parser_type, str) or not parser_type:
        parser_type = "unknown"
    if not isinstance(tool_call_start, str) or not tool_call_start:
        raise BackendError(
            "tooling_not_supported",
            "model tokenizer does not expose a tool-call start token",
            False,
        )

    return ToolCallingContext(
        tools=tools,
        parser_type=parser_type,
        tool_choice=normalized_choice,
        tool_call_start=tool_call_start,
        tool_call_end=tool_call_end,
        tool_parser=tool_parser,
        named_tool_name=named_tool_name,
        requires_tool_call=requires_tool_call,
    )


def consume_response(ctx: ToolCallingContext, response: Any) -> list[dict[str, Any]]:
    text = getattr(response, "text", "")
    if not isinstance(text, str) or text == "":
        return []

    remaining = text
    while remaining:
        if ctx.in_tool_call:
            remaining = _consume_tool_text(ctx, remaining)
        else:
            remaining = _consume_normal_text(ctx, remaining)

        if ctx.pending_error is not None:
            break

    return ctx.take_pending_events()


def finalize(
    ctx: ToolCallingContext,
    *,
    terminal_kind: str = "completed",
) -> BackendError | None:
    if terminal_kind not in {"completed", "cancelled", "failed"}:
        raise ValueError(f"unsupported terminal kind: {terminal_kind!r}")

    if ctx.text_buffer:
        ctx.pending_events.append({"kind": "output_text_delta", "delta": ctx.text_buffer})
        ctx.text_buffer = ""

    if ctx.in_tool_call:
        if ctx.tool_end_buffer:
            _append_tool_argument_fragment(ctx, ctx.tool_end_buffer)
            ctx.tool_end_buffer = ""

        if terminal_kind == "completed":
            _finalize_active_tool_call(ctx)
        else:
            _reset_active_tool_call(ctx)

    if ctx.pending_error is not None:
        return ctx.pending_error

    if terminal_kind == "completed" and ctx.requires_tool_call and not ctx.saw_tool_call:
        if ctx.named_tool_name is not None:
            return BackendError(
                "tool_choice_not_satisfied",
                f"model did not emit required tool call {ctx.named_tool_name}",
                False,
            )
        return BackendError(
            "tool_choice_not_satisfied",
            "model did not emit any required tool calls",
            False,
        )

    return None


def _consume_normal_text(ctx: ToolCallingContext, text: str) -> str:
    combined = ctx.text_buffer + text
    ctx.text_buffer = ""
    start_pos = combined.find(ctx.tool_call_start)

    if start_pos == -1:
        safe_text, suffix = _split_partial_marker(combined, ctx.tool_call_start)
        if safe_text:
            ctx.pending_events.append({"kind": "output_text_delta", "delta": safe_text})
        ctx.text_buffer = suffix
        return ""

    if start_pos > 0:
        ctx.pending_events.append({"kind": "output_text_delta", "delta": combined[:start_pos]})

    _start_tool_call(ctx)
    return combined[start_pos + len(ctx.tool_call_start) :]


def _consume_tool_text(ctx: ToolCallingContext, text: str) -> str:
    if ctx.tool_call_end == "":
        _append_tool_argument_fragment(ctx, text)
        return ""

    combined = ctx.tool_end_buffer + text
    ctx.tool_end_buffer = ""
    end_pos = combined.find(ctx.tool_call_end)

    if end_pos == -1:
        safe_text, suffix = _split_partial_marker(combined, ctx.tool_call_end)
        _append_tool_argument_fragment(ctx, safe_text)
        ctx.tool_end_buffer = suffix
        return ""

    _append_tool_argument_fragment(ctx, combined[:end_pos])
    _finalize_active_tool_call(ctx)
    return combined[end_pos + len(ctx.tool_call_end) :]


def _split_partial_marker(text: str, marker: str) -> tuple[str, str]:
    if marker == "":
        return text, ""

    max_overlap = min(len(text), len(marker) - 1)
    for overlap in range(max_overlap, 0, -1):
        if text.endswith(marker[:overlap]):
            return text[:-overlap], text[-overlap:]
    return text, ""


def _start_tool_call(ctx: ToolCallingContext) -> None:
    index = ctx.next_tool_index
    ctx.next_tool_index += 1
    ctx.in_tool_call = True
    ctx.current_tool_text = ""
    ctx.tool_end_buffer = ""
    ctx.active_tool_call_id = f"call_{index}"
    ctx.active_tool_index = index
    ctx.active_tool_name = _inferred_tool_name(ctx)
    ctx.active_type_emitted = False
    ctx.active_name_emitted = False


def _append_tool_argument_fragment(ctx: ToolCallingContext, fragment: str) -> None:
    if fragment == "":
        return

    if ctx.active_tool_call_id is None or ctx.active_tool_index is None:
        _start_tool_call(ctx)

    ctx.current_tool_text += fragment

    function_delta: dict[str, Any] = {"arguments_delta": fragment}
    if ctx.active_tool_name is not None and not ctx.active_name_emitted:
        function_delta["name"] = ctx.active_tool_name
        ctx.active_name_emitted = True

    delta: dict[str, Any] = {"index": ctx.active_tool_index, "function": function_delta}
    if not ctx.active_type_emitted:
        delta["type"] = "function"
        ctx.active_type_emitted = True

    ctx.pending_events.append(
        {
            "kind": "tool_call_delta",
            "tool_call_id": ctx.active_tool_call_id,
            "delta": delta,
        }
    )
    ctx.saw_tool_call = True


def _emit_tool_name_delta(ctx: ToolCallingContext, name: str) -> None:
    if ctx.active_tool_call_id is None or ctx.active_tool_index is None or ctx.active_name_emitted:
        return

    ctx.active_tool_name = name
    delta: dict[str, Any] = {
        "index": ctx.active_tool_index,
        "function": {"name": name},
    }
    if not ctx.active_type_emitted:
        delta["type"] = "function"
        ctx.active_type_emitted = True

    ctx.pending_events.append(
        {
            "kind": "tool_call_delta",
            "tool_call_id": ctx.active_tool_call_id,
            "delta": delta,
        }
    )
    ctx.active_name_emitted = True
    ctx.saw_tool_call = True


def _finalize_active_tool_call(ctx: ToolCallingContext) -> None:
    if ctx.active_tool_call_id is None or ctx.active_tool_index is None:
        ctx.in_tool_call = False
        return

    try:
        parsed = ctx.tool_parser(ctx.current_tool_text, ctx.tools)
    except Exception as exc:
        ctx.pending_error = BackendError(
            "tool_call_parse_failed",
            f"failed to parse tool call: {exc}",
            False,
        )
        _reset_active_tool_call(ctx)
        return

    parsed_calls = parsed if isinstance(parsed, list) else [parsed]
    if len(parsed_calls) != 1:
        ctx.pending_error = BackendError(
            "tool_call_parse_failed",
            f"tool parser returned {len(parsed_calls)} calls for a single tool block",
            False,
        )
        _reset_active_tool_call(ctx)
        return

    try:
        normalized = _normalize_parsed_tool_call(parsed_calls[0])
    except ValueError as exc:
        ctx.pending_error = BackendError("tool_call_parse_failed", str(exc), False)
        _reset_active_tool_call(ctx)
        return

    name = normalized["name"]
    if ctx.named_tool_name is not None and name != ctx.named_tool_name:
        ctx.pending_error = BackendError(
            "tool_choice_not_satisfied",
            f"model emitted tool {name!r} but tool_choice requires {ctx.named_tool_name!r}",
            False,
        )
        _reset_active_tool_call(ctx)
        return

    if ctx.active_tool_name is not None and name != ctx.active_tool_name:
        ctx.pending_error = BackendError(
            "tool_call_parse_failed",
            f"parsed tool name {name!r} did not match emitted tool name {ctx.active_tool_name!r}",
            False,
        )
        _reset_active_tool_call(ctx)
        return

    _emit_tool_name_delta(ctx, name)
    _reset_active_tool_call(ctx)


def _reset_active_tool_call(ctx: ToolCallingContext) -> None:
    ctx.in_tool_call = False
    ctx.current_tool_text = ""
    ctx.tool_end_buffer = ""
    ctx.active_tool_call_id = None
    ctx.active_tool_index = None
    ctx.active_tool_name = None
    ctx.active_type_emitted = False
    ctx.active_name_emitted = False


def _inferred_tool_name(ctx: ToolCallingContext) -> str | None:
    if ctx.named_tool_name is not None:
        return ctx.named_tool_name
    if len(ctx.tools) != 1:
        return None

    tool = ctx.tools[0]
    function = tool.get("function") if isinstance(tool, dict) else None
    name = function.get("name") if isinstance(function, dict) else None
    return name if isinstance(name, str) and name else None


def _normalize_parsed_tool_call(parsed_call: Any) -> dict[str, str | None]:
    if not isinstance(parsed_call, dict):
        raise ValueError(f"tool parser returned unsupported payload: {parsed_call!r}")

    name = parsed_call.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"tool parser returned invalid function name: {name!r}")

    tool_call_id = parsed_call.get("id")
    if tool_call_id is not None and (not isinstance(tool_call_id, str) or not tool_call_id):
        raise ValueError(f"tool parser returned invalid tool call id: {tool_call_id!r}")

    return {"id": tool_call_id, "name": name}


def _normalize_tool_choice(
    tool_choice: Any,
) -> tuple[str | dict[str, Any] | None, str | None, bool]:
    if tool_choice is None:
        return "auto", None, False
    if isinstance(tool_choice, str):
        if tool_choice == "none":
            return "none", None, False
        if tool_choice not in {"auto", "required"}:
            raise BackendError(
                "invalid_generation_params",
                f"unsupported tool_choice value: {tool_choice!r}",
                False,
            )
        return tool_choice, None, tool_choice == "required"
    if isinstance(tool_choice, dict):
        function = tool_choice.get("function")
        name = function.get("name") if isinstance(function, dict) else None
        if not isinstance(name, str) or not name:
            raise BackendError(
                "invalid_generation_params",
                "named tool_choice must include function.name",
                False,
            )
        return tool_choice, name, True
    raise BackendError(
        "invalid_generation_params",
        f"unsupported tool_choice payload: {tool_choice!r}",
        False,
    )


def _decode_tools_json(payload: Any) -> list[dict[str, Any]]:
    if payload in (None, b"", ""):
        return []

    decoded = _decode_json_param(payload, "tools_json")
    if not isinstance(decoded, list):
        raise BackendError(
            "invalid_generation_params",
            f"tools_json must decode to a JSON array, got {type(decoded).__name__}",
            False,
        )
    return decoded


def _decode_tool_choice_json(payload: Any) -> Any:
    if payload in (None, b"", ""):
        return None
    return _decode_json_param(payload, "tool_choice_json")


def _decode_json_param(payload: Any, field_name: str) -> Any:
    if isinstance(payload, str):
        raw = payload
    elif isinstance(payload, (bytes, bytearray, memoryview)):
        try:
            raw = bytes(payload).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise BackendError(
                "invalid_generation_params",
                f"{field_name} is not valid UTF-8: {exc}",
                False,
            ) from exc
    else:
        raise BackendError(
            "invalid_generation_params",
            f"{field_name} has unsupported type: {type(payload).__name__}",
            False,
        )

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BackendError(
            "invalid_generation_params",
            f"{field_name} is not valid JSON: {exc}",
            False,
        ) from exc
