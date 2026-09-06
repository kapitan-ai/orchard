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
