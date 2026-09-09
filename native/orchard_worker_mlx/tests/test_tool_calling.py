from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from orchard_worker_mlx.tool_calling import ToolCallingContext, consume_response, finalize


def make_context(**overrides) -> ToolCallingContext:
    fields = dict(
        tools=[
            {"type": "function", "function": {"name": name, "parameters": {}}}
            for name in ("read", "lookup")
        ],
        parser_type="json_tools",
        tool_choice="auto",
        tool_call_start="<tool_call>",
        tool_call_end="</tool_call>",
        tool_parser=lambda text, tools: json.loads(text.strip()),
    )
    fields.update(overrides)
    return ToolCallingContext(**fields)


def consume(context: ToolCallingContext, text: str) -> list[dict]:
    return consume_response(context, SimpleNamespace(text=text))


def test_spec_7_5_2_tool_arguments_come_from_parser_not_model_wrapper() -> None:
    # The pinned MLX-LM json_tools parser returns json.loads(text.strip()).
    context = make_context()
    events = consume_response(
        context,
        SimpleNamespace(text='<tool_call>{"name":"read","arguments":{"path":"fixture.txt"}}'),
    )
    assert events == [], "Unparsed model syntax must not cross the Worker Runtime boundary"

    events = consume_response(context, SimpleNamespace(text="</tool_call>"))
    assert finalize(context) is None
    assert len(events) == 1
    call = events[0]
    assert call["kind"] == "tool_call_delta"
    assert call["delta"]["function"]["name"] == "read"
    assert json.loads(call["delta"]["function"]["arguments_delta"]) == {"path": "fixture.txt"}


@pytest.mark.parametrize("chunk_size", [1, 2, 3, 7, 64, 256])
def test_split_markers_and_escaped_unicode_arguments_preserve_parsed_values(
    chunk_size: int,
) -> None:
    arguments = {"path": 'nested/"quoted"\\file.txt', "query": "新加坡", "options": [True, None, 2]}
    body = json.dumps({"name": "read", "arguments": arguments}, ensure_ascii=False)
    stream = f"Before <tool_call>{body}</tool_call> after"
    context = make_context()
    events = []
    for start in range(0, len(stream), chunk_size):
        events.extend(consume(context, stream[start : start + chunk_size]))
    assert finalize(context) is None
    events.extend(context.take_pending_events())
    calls = [event for event in events if event["kind"] == "tool_call_delta"]
    assert len(calls) == 1
    assert json.loads(calls[0]["delta"]["function"]["arguments_delta"]) == arguments
    assert "".join(event["delta"] for event in events if event["kind"] == "output_text_delta") == (
        "Before  after"
    )


def test_multiple_parser_results_and_blocks_have_distinct_ordered_ids() -> None:
    context = make_context()
    calls = [
        {"id": "same", "name": name, "arguments": {"n": n}}
        for n, name in enumerate(("read", "lookup"))
    ]
    first = consume(context, f"<tool_call>{json.dumps(calls)}</tool_call>")
    second = consume(context, '<tool_call>{"name":"read","arguments":{}}</tool_call>')
    assert finalize(context) is None
    events = first + second
    assert [event["tool_call_id"] for event in events] == ["call_0", "call_1", "call_2"]
    assert [event["delta"]["index"] for event in events] == [0, 1, 2]
    assert [event["delta"]["function"]["name"] for event in events] == ["read", "lookup", "read"]


@pytest.mark.parametrize(
    "parsed",
    [
        [],
        None,
        "private-generated-content",
        {"name": "", "arguments": {}},
        {"name": "unrequested", "arguments": {}},
        {"name": "read"},
        {"name": "read", "arguments": '{"path":"private-generated-content"}'},
        {"name": "read", "arguments": []},
        {"name": "read", "arguments": {"n": float("nan")}},
        {"name": "read", "arguments": {"value": object()}},
        [
            {"name": "read", "arguments": {"path": "private-generated-content"}},
            {"name": "unrequested", "arguments": {}},
        ],
    ],
)
def test_invalid_parser_results_publish_no_calls_and_no_generated_error_content(parsed) -> None:
    context = make_context(tool_parser=lambda text, tools: parsed)
    assert consume(context, "<tool_call>private-generated-content</tool_call>") == []
    error = finalize(context)
    assert error is not None
    assert error.code == "tool_call_parse_failed"
    assert "private-generated-content" not in error.message
    assert not context.saw_tool_call


def test_parser_exception_does_not_echo_model_output() -> None:
    parser = Mock(side_effect=ValueError("private-generated-content"))
    context = make_context(tool_parser=parser)
    assert consume(context, "<tool_call>private-generated-content</tool_call>") == []
    error = finalize(context)
    assert error is not None
    assert error.message == "provider could not parse the tool call"
    parser.assert_called_once()


@pytest.mark.parametrize("terminal", ["cancelled", "failed", "completed", "truncated"])
def test_unclosed_frame_never_reaches_parser_or_publishes_a_call(terminal: str) -> None:
    parser = Mock(return_value={"name": "read", "arguments": {}})
    context = make_context(tool_parser=parser)
    assert consume(context, '<tool_call>{"name":"read","arguments":{}}</tool_') == []
    error = finalize(context, terminal_kind=terminal)
    parser.assert_not_called()
    assert context.take_pending_events() == []
    assert not context.in_tool_call
    assert context.tool_text_parts == []
    if terminal in {"completed", "truncated"}:
        assert error is not None
        assert error.code == "tool_call_parse_failed"
    else:
        assert error is None


@pytest.mark.parametrize("terminal", ["cancelled", "failed", "completed", "truncated"])
def test_delimiter_free_parser_requires_clean_generation_stop(terminal: str) -> None:
    parser = Mock(return_value={"name": "read", "arguments": {"path": "fixture.txt"}})
    context = make_context(tool_parser=parser, tool_call_end="")
    assert consume(context, '<tool_call>read[ARGS]{"path":"fixture.txt"}') == []
    finalize(context, terminal_kind=terminal)
    events = context.take_pending_events()
    if terminal == "completed":
        parser.assert_called_once()
        assert len(events) == 1
        assert json.loads(events[0]["delta"]["function"]["arguments_delta"]) == {
            "path": "fixture.txt"
        }
    else:
        parser.assert_not_called()
        assert events == []


def test_wrong_named_choice_does_not_publish_any_call_in_block() -> None:
    context = make_context(named_tool_name="read", requires_tool_call=True)
    calls = [{"name": name, "arguments": {}} for name in ("read", "lookup")]
    assert consume(context, f"<tool_call>{json.dumps(calls)}</tool_call>") == []
    error = finalize(context)
    assert error is not None
    assert error.code == "tool_choice_not_satisfied"


def test_valid_call_remains_visible_when_a_later_block_fails() -> None:
    context = make_context()
    events = consume(context, '<tool_call>{"name":"read","arguments":{}}</tool_call>')
    assert len(events) == 1
    assert consume(context, '<tool_call>{"name":"unrequested","arguments":{}}</tool_call>') == []
    assert finalize(context) is not None
    assert context.take_pending_events() == []
    assert events[0]["tool_call_id"] == "call_0"
