from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from orchard_worker_mlx.tool_calling import ToolCallingContext, consume_response, finalize


@pytest.mark.parametrize(
    ("parser_name", "body", "arguments"),
    [
        (
            "json_tools",
            '{"name":"read","arguments":{"path":"fixture.txt"}}',
            {"path": "fixture.txt"},
        ),
        (
            "qwen3_coder",
            "<function=read>\n<parameter=path>\nfixture.txt\n</parameter>\n</function>",
            {"path": "fixture.txt"},
        ),
        ("mistral", 'read[ARGS]{"path":"fixture.txt"}', {"path": "fixture.txt"}),
    ],
)
def test_pinned_mlx_lm_parser_arguments_cross_worker_boundary(parser_name, body, arguments) -> None:
    parser = pytest.importorskip(f"mlx_lm.tool_parsers.{parser_name}")
    tools = [
        {
            "type": "function",
            "function": {
                "name": "read",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"],
                },
            },
        }
    ]
    context = ToolCallingContext(
        tools=tools,
        parser_type=parser_name,
        tool_choice="auto",
        tool_call_start=parser.tool_call_start,
        tool_call_end=parser.tool_call_end,
        tool_parser=parser.parse_tool_call,
    )
    text = parser.tool_call_start + body + parser.tool_call_end
    events = []
    for char in text:
        events.extend(consume_response(context, SimpleNamespace(text=char)))
    assert finalize(context) is None
    events.extend(context.take_pending_events())
    assert len(events) == 1
    assert events[0]["delta"]["function"]["name"] == "read"
    assert json.loads(events[0]["delta"]["function"]["arguments_delta"]) == arguments


def _pinned_json_tools_context() -> tuple[ToolCallingContext, object]:
    parser = pytest.importorskip("mlx_lm.tool_parsers.json_tools")
    tools = [
        {
            "type": "function",
            "function": {"name": "read", "parameters": {"type": "object"}},
        }
    ]
    context = ToolCallingContext(
        tools=tools,
        parser_type="json_tools",
        tool_choice="auto",
        tool_call_start=parser.tool_call_start,
        tool_call_end=parser.tool_call_end,
        tool_parser=parser.parse_tool_call,
    )
    return context, parser


def _consume_pinned_json_tools(body: str) -> tuple[list[dict], object, ToolCallingContext]:
    context, parser = _pinned_json_tools_context()
    text = parser.tool_call_start + body + parser.tool_call_end
    events = consume_response(context, SimpleNamespace(text=text))
    return events, parser, context


def test_pinned_json_tools_preserves_post_parse_large_integer_values() -> None:
    arguments = {
        "positive": 9_007_199_254_740_993,
        "negative": -9_007_199_254_740_993,
    }
    body = json.dumps({"name": "read", "arguments": arguments})

    events, _parser, context = _consume_pinned_json_tools(body)

    assert finalize(context) is None
    assert len(events) == 1
    assert events[0]["delta"]["function"]["arguments_delta"] == (
        '{"positive":9007199254740993,"negative":-9007199254740993}'
    )


@pytest.mark.parametrize(
    "body",
    [
        '{"name":"unknown","arguments":{}}',
        '{"name":"read","arguments":[]}',
        '{"name":"read","arguments":{"path":"fixture.txt"}',
        '{"name":"read","arguments":[1,2}',
    ],
)
def test_pinned_json_tools_rejects_unknown_non_object_and_malformed_calls(body: str) -> None:
    events, _parser, context = _consume_pinned_json_tools(body)

    assert events == []
    error = finalize(context)
    assert error is not None
    assert error.code == "tool_call_parse_failed"
    assert context.take_pending_events() == []


def test_pinned_json_tools_keeps_earlier_valid_block_when_later_block_is_invalid() -> None:
    context, parser = _pinned_json_tools_context()
    valid = (
        parser.tool_call_start
        + '{"name":"read","arguments":{"value":9007199254740993}}'
        + parser.tool_call_end
    )
    invalid = parser.tool_call_start + '{"name":"unknown","arguments":{}}' + parser.tool_call_end

    events = consume_response(context, SimpleNamespace(text=valid))
    assert consume_response(context, SimpleNamespace(text=invalid)) == []

    error = finalize(context)
    assert error is not None
    assert error.code == "tool_call_parse_failed"
    assert len(events) == 1
    assert events[0]["delta"]["function"]["arguments_delta"] == ('{"value":9007199254740993}')


@pytest.mark.parametrize(
    "body", ['{"name":"read","arguments":{"path":"x"}', '{"name":"read","arguments":[1,2']
)
def test_pinned_json_tools_discards_truncated_object_and_array(body: str) -> None:
    context, parser = _pinned_json_tools_context()

    events = consume_response(context, SimpleNamespace(text=parser.tool_call_start + body))
    error = finalize(context, terminal_kind="truncated")

    assert events == []
    assert error is not None
    assert error.code == "tool_call_parse_failed"
    assert context.take_pending_events() == []
