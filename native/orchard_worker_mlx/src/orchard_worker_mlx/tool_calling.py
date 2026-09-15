from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from orchard_worker_mlx.backends import BackendError
from orchard_worker_mlx.partial_markers import split_partial_marker


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
    tool_text_parts: list[str] = field(default_factory=list)
    next_tool_index: int = 0
    pending_events: list[dict[str, Any]] = field(default_factory=list)
    pending_error: BackendError | None = None
    text_buffer: str = ""
    tool_end_buffer: str = ""

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
    return consume_text(ctx, getattr(response, "text", ""))


def consume_text(ctx: ToolCallingContext, text: str) -> list[dict[str, Any]]:
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
    if terminal_kind not in {"completed", "cancelled", "failed", "truncated"}:
        raise ValueError(f"unsupported terminal kind: {terminal_kind!r}")

    if ctx.text_buffer:
        ctx.pending_events.append({"kind": "output_text_delta", "delta": ctx.text_buffer})
        ctx.text_buffer = ""

    if ctx.in_tool_call:
        if ctx.tool_end_buffer:
            ctx.tool_text_parts.append(ctx.tool_end_buffer)
            ctx.tool_end_buffer = ""

        if terminal_kind == "completed" and not ctx.tool_call_end:
            _finalize_active_tool_call(ctx)
        else:
            if terminal_kind in {"completed", "truncated"}:
                ctx.pending_error = BackendError(
                    "tool_call_parse_failed", "generation ended before a complete tool call", False
                )
            _reset_active_tool_call(ctx)

    if ctx.pending_error is not None:
        return ctx.pending_error

    if (
        terminal_kind in {"completed", "truncated"}
        and ctx.requires_tool_call
        and not ctx.saw_tool_call
    ):
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
        safe_text, suffix = split_partial_marker(combined, ctx.tool_call_start)
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
        ctx.tool_text_parts.append(text)
        return ""

    combined = ctx.tool_end_buffer + text
    ctx.tool_end_buffer = ""
    end_pos = combined.find(ctx.tool_call_end)

    if end_pos == -1:
        safe_text, suffix = split_partial_marker(combined, ctx.tool_call_end)
        ctx.tool_text_parts.append(safe_text)
        ctx.tool_end_buffer = suffix
        return ""

    ctx.tool_text_parts.append(combined[:end_pos])
    _finalize_active_tool_call(ctx)
    return combined[end_pos + len(ctx.tool_call_end) :]


def _start_tool_call(ctx: ToolCallingContext) -> None:
    ctx.in_tool_call = True
    ctx.tool_text_parts.clear()
    ctx.tool_end_buffer = ""


def _finalize_active_tool_call(ctx: ToolCallingContext) -> None:
    try:
        parsed = ctx.tool_parser("".join(ctx.tool_text_parts), ctx.tools)
    except Exception:
        # Provider parser exceptions can include generated content; keep them local.
        ctx.pending_error = BackendError(
            "tool_call_parse_failed", "provider could not parse the tool call", False
        )
        _reset_active_tool_call(ctx)
        return

    parsed_calls = parsed if isinstance(parsed, list) else [parsed]
    if not parsed_calls:
        ctx.pending_error = BackendError(
            "tool_call_parse_failed", "provider returned no tool calls", False
        )
        _reset_active_tool_call(ctx)
        return

    try:
        normalized = [_normalize_parsed_tool_call(ctx, call) for call in parsed_calls]
    except BackendError as exc:
        ctx.pending_error = exc
        _reset_active_tool_call(ctx)
        return

    for name, arguments in normalized:
        index = ctx.next_tool_index
        ctx.next_tool_index += 1
        ctx.pending_events.append(
            {
                "kind": "tool_call_delta",
                "tool_call_id": f"call_{index}",
                "delta": {
                    "index": index,
                    "type": "function",
                    "function": {"name": name, "arguments_delta": arguments},
                },
            }
        )
    ctx.saw_tool_call = True
    _reset_active_tool_call(ctx)


def _reset_active_tool_call(ctx: ToolCallingContext) -> None:
    ctx.in_tool_call = False
    ctx.tool_text_parts.clear()
    ctx.tool_end_buffer = ""


def _normalize_parsed_tool_call(ctx: ToolCallingContext, parsed_call: Any) -> tuple[str, str]:
    if not isinstance(parsed_call, dict):
        raise BackendError(
            "tool_call_parse_failed", "provider returned an invalid tool call", False
        )

    name = parsed_call.get("name")
    if not isinstance(name, str) or not name:
        raise BackendError(
            "tool_call_parse_failed", "provider returned an invalid tool name", False
        )

    if ctx.named_tool_name is not None and name != ctx.named_tool_name:
        raise BackendError(
            "tool_choice_not_satisfied", "model did not emit the required function", False
        )
    requested_names = {
        tool["function"]["name"]
        for tool in ctx.tools
        if isinstance(tool, dict)
        and isinstance(tool.get("function"), dict)
        and isinstance(tool["function"].get("name"), str)
    }
    if name not in requested_names:
        raise BackendError("tool_call_parse_failed", "model emitted an unrequested function", False)

    arguments = parsed_call.get("arguments")
    if not isinstance(arguments, dict):
        raise BackendError(
            "tool_call_parse_failed", "provider tool arguments must be a JSON object", False
        )
    try:
        encoded = json.dumps(arguments, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError):
        raise BackendError(
            "tool_call_parse_failed", "provider tool arguments are not valid JSON", False
        ) from None
    return name, encoded


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
