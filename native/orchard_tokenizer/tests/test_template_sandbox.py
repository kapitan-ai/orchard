from __future__ import annotations

import pytest

from orchard_tokenizer.cli import _chat_template_environment
from orchard_tokenizer.safe_segmented import (
    SafeSegmentedError,
    dual_render_guard,
    tag_caller_strings,
    walk_rendered,
)
from orchard_tokenizer.template_sandbox import MarkerPolicy


@pytest.mark.parametrize(
    ("template", "expected", "caller_count"),
    [
        ("{{ messages[0].content ~ messages[0].content }}", "hellohello", 2),
        ("{{ messages[0].content + messages[0].content }}", "hellohello", 2),
        ("{% macro echo(x) %}{{ x }}{% endmacro %}{{ echo(messages[0].content) }}", "hello", 1),
        ("{% set captured %}{{ messages[0].content }}{% endset %}{{ captured }}", "hello", 1),
        ("{% for message in messages[:] %}{{ message.content }}{% endfor %}", "hello", 1),
        ("{{ (messages | first).content }}", "hello", 1),
        ("{{ dict(value=messages[0].content).get('value') }}", "hello", 1),
        (
            "{% for key, value in dict(x=messages[0].content) | items %}{{ value }}{% endfor %}",
            "hello",
            1,
        ),
        ("{{ messages[0].content | string | trim }}", "hello", 1),
        ("{{ messages[0].content.replace('-', '_') }}", "hello", 1),
        ("{{ messages[0].content | safe }}", "hello", 1),
        ("{{ messages[0].content.count('h') }}", "1", 0),
        (
            "{% if messages[0].content is iterable %}{{ messages[0].content }}{% endif %}",
            "hello",
            1,
        ),
        ("{{ 'unused' }}", "unused", 0),
        ("{{ 'constant'.replace('constant', 'safe') }}{{ 'slice'[0:2] }}", "safesl", 0),
    ],
)
def test_audited_operations_preserve_caller_envelopes(template, expected, caller_count):
    inputs = [{"role": "user", "content": "hello"}]
    tagged, pairs = tag_caller_strings(inputs, [], None, "2" * 39)
    baseline = _chat_template_environment().from_string(template).render(messages=inputs)
    rendered = (
        _chat_template_environment(marker_pairs=pairs)
        .from_string(template)
        .render(messages=tagged["input_items"])
    )
    dual_render_guard(baseline, rendered, pairs)
    segments = walk_rendered(rendered, pairs)
    assert "".join(segment.text for segment in segments) == expected
    assert sum(segment.kind == "caller" for segment in segments) == caller_count


def test_serialization_policy_rejects_lost_duplicated_or_unbalanced_markers():
    tagged, pairs = tag_caller_strings([{"role": "user", "content": "hello"}], [], None, "2" * 39)
    value = tagged["input_items"][0]["content"]
    policy = MarkerPolicy(pairs)
    for bad in ("hello", str(value) + str(value), pairs[0].end + "hello" + pairs[0].begin):
        with pytest.raises(SafeSegmentedError):
            policy.serialized(value, bad, "test_serialization")


def test_empty_trim_does_not_declassify_another_use_of_the_leaf():
    inputs = [{"role": "user", "content": "\n"}]
    tagged, pairs = tag_caller_strings(inputs, [], None, "2" * 39)
    template = "{{ messages[0].content | trim }}{{ messages[0].content }}"
    rendered = (
        _chat_template_environment(marker_pairs=pairs)
        .from_string(template)
        .render(messages=tagged["input_items"])
    )
    dual_render_guard("\n", rendered, pairs)
    assert [
        (segment.kind, segment.text) for segment in walk_rendered(rendered, pairs) if segment.text
    ] == [("caller", "\n")]


def test_underlying_sandbox_callable_restrictions_are_retained():
    from jinja2.exceptions import SecurityError

    def forbidden(value):
        return value

    forbidden.unsafe_callable = True
    tagged, pairs = tag_caller_strings([{"role": "user", "content": "hello"}], [], None, "2" * 39)
    environment = _chat_template_environment(marker_pairs=pairs)
    environment.globals["forbidden"] = forbidden
    with pytest.raises(SecurityError):
        environment.from_string("{{ forbidden(messages[0].content) }}").render(
            messages=tagged["input_items"]
        )


@pytest.mark.parametrize(
    "template",
    [
        "{% macro echo(x) %}{{ x }}{% endmacro %}{{ echo(messages[0].content)[0:] }}",
        "{% set captured %}{{ messages[0].content }}{% endset %}"
        "{% for char in captured %}{{ char }}{% endfor %}",
        "{{ ({'x': messages[0].content} | tojson)[0:] }}",
        "{{ (messages[0].content | safe).split('_') }}",
        "{{ (messages[0].content + '') | replace('_', '') }}",
        "{% for char in [messages[0].content] | map(attribute=0) %}{{ char }}{% endfor %}",
    ],
)
def test_serialization_and_structural_routes_cannot_launder_markers(template):
    tagged, pairs = tag_caller_strings([{"role": "user", "content": "hello"}], [], None, "2" * 39)
    with pytest.raises(SafeSegmentedError):
        _chat_template_environment(marker_pairs=pairs).from_string(template).render(
            messages=tagged["input_items"]
        )
