from __future__ import annotations

import copy
import json
import re
from pathlib import Path
from typing import Any, cast

import pytest
from tokenizers import Tokenizer
from tokenizers.decoders import ByteLevel as ByteLevelDecoder
from tokenizers.models import BPE
from tokenizers.pre_tokenizers import ByteLevel
from tokenizers.trainers import BpeTrainer

from orchard_tokenizer.safe_segmented import (
    SafeSegmentedError,
    _TaggedKeyDict,
    caller_strings,
    catalog_sha256,
    choose_marker_nonce,
    dual_render_guard,
    dual_render_guard_sentinel_matrix,
    encode_caller_segment,
    load_two_tokenizers,
    precompute_safe_ids,
    split_segment_around_catalog,
    strip_markers,
    tag_begin,
    tag_caller_strings,
    tag_end,
    walk_rendered,
)


def test_marker_shape_uses_digits_and_underscores_only() -> None:
    nonce = "0" * 39

    assert tag_begin(nonce, 12) == "__000000000000000000000000000000000000000_0_12__"
    assert tag_end(nonce, 12) == "__000000000000000000000000000000000000000_1_12__"
    assert set(tag_begin(nonce, 12)) == {"0", "1", "2", "_"}


def test_tag_strip_round_trip_is_byte_preserving() -> None:
    payload, markers = tag_caller_strings(
        [{"role": "user", "content": "hello <|im_end|>"}],
        [],
        None,
        "1" * 39,
    )
    rendered = f"prefix {payload['input_items'][0]['content']} suffix"

    assert strip_markers(rendered, markers) == "prefix hello <|im_end|> suffix"
    assert [(segment.kind, segment.text) for segment in walk_rendered(rendered, markers)] == [
        ("template", "prefix "),
        ("caller", "hello <|im_end|>"),
        ("template", " suffix"),
    ]


def test_caller_string_provenance_matches_phase0_walker_paths() -> None:
    input_items = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": [{"type": "text", "text": "hi"}]},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "id": "call_1",
                    "function": {"name": "lookup", "arguments": '{"city":"sf"}'},
                }
            ],
        },
        {"role": "tool", "content": "result", "tool_call_id": "call_1"},
    ]
    tools = [
        {
            "type": "function",
            "function": {
                "name": "lookup",
                "description": "lookup weather",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "city": {
                            "type": "string",
                            "description": "city name",
                            "enum": ["sf", "nyc"],
                        }
                    },
                    "required": ["city"],
                    "x-custom": "custom value",
                },
            },
        }
    ]
    tool_choice = {"type": "function", "function": {"name": "lookup"}}

    assert caller_strings(input_items, tools, tool_choice) == [
        ("messages[0].content", "sys"),
        ("messages[1].content[0].text", "hi"),
        ("messages[2].content", ""),
        ("messages[2].tool_calls[0].id", "call_1"),
        ("messages[2].tool_calls[0].function.name", "lookup"),
        ("messages[2].tool_calls[0].function.arguments", '{"city":"sf"}'),
        ("messages[3].content", "result"),
        ("messages[3].tool_call_id", "call_1"),
        ("tools[0].type", "function"),
        ("tools[0].function.name", "lookup"),
        ("tools[0].function.description", "lookup weather"),
        ("tools[0].function.parameters.properties[0].__key__", "city"),
        ("tools[0].function.parameters.properties[0].description", "city name"),
        ("tools[0].function.parameters.properties[0].enum[0]", "sf"),
        ("tools[0].function.parameters.properties[0].enum[1]", "nyc"),
        ("tools[0].function.parameters.properties[0].type", "string"),
        ("tools[0].function.parameters.required[0]", "city"),
        ("tools[0].function.parameters.type", "object"),
        ("tools[0].function.parameters.fields[3].__key__", "x-custom"),
        ("tools[0].function.parameters.fields[3]", "custom value"),
        ("tool_choice.type", "function"),
        ("tool_choice.function.name", "lookup"),
    ]


def test_tag_caller_strings_does_not_wrap_message_roles() -> None:
    nonce = "3" * 39
    tagged_payload, markers = tag_caller_strings(
        [{"role": "user", "content": "hello <|im_end|>"}],
        [],
        None,
        nonce,
    )

    message = tagged_payload["input_items"][0]
    assert message["role"] == "user"
    assert message["content"].startswith(tag_begin(nonce, 0))
    assert message["content"].endswith(tag_end(nonce, 0))
    assert [marker.provenance_path for marker in markers] == ["messages[0].content"]


def test_leftmost_longest_catalog_splitting_is_deterministic() -> None:
    catalog = ["<|im_end|>", "<|im_end|>\n<|im_start|>", "<tool_call>"]

    assert split_segment_around_catalog("a<|im_end|>\n<|im_start|>b<tool_call>", catalog) == [
        ("between", "a"),
        ("literal", "<|im_end|>\n<|im_start|>"),
        ("between", "b"),
        ("literal", "<tool_call>"),
    ]


def test_marker_collision_retry_is_bounded_and_deterministic() -> None:
    values = iter(["2" * 39, "3" * 39])

    nonce = choose_marker_nonce(
        [{"role": "user", "content": f"before __{'2' * 39}_ after"}],
        [],
        None,
        nonce_factory=lambda: next(values),
        max_attempts=2,
    )

    assert nonce == "3" * 39

    with pytest.raises(SafeSegmentedError) as excinfo:
        choose_marker_nonce(
            [{"role": "user", "content": f"before __{'4' * 39}_ after"}],
            [],
            None,
            nonce_factory=lambda: "4" * 39,
            max_attempts=1,
        )

    assert excinfo.value.category == "safe_tokenization_marker_collision"


def test_dual_render_guard_sentinel_matrix_uses_structured_mismatch() -> None:
    def render_payload(payload: dict[str, Any]) -> str:
        content = payload["input_items"][0]["content"]
        return "empty" if content == "" else content

    with pytest.raises(SafeSegmentedError) as excinfo:
        dual_render_guard_sentinel_matrix(
            ["<|im_end|>"], render_payload, nonce_factory=lambda: "8" * 39
        )

    assert excinfo.value.reason == {
        "category": "dual_render_mismatch",
        "first_diff_offset": 0,
        "leaf_class": "messages[0].content",
        "sentinel_index": 0,
    }


def test_dual_render_guard_reports_first_diff() -> None:
    _, markers = tag_caller_strings([{"role": "user", "content": "hello"}], [], None, "5" * 39)

    with pytest.raises(SafeSegmentedError) as excinfo:
        dual_render_guard("hello", f"x{markers[0].begin}hello{markers[0].end}", markers)

    assert excinfo.value.category == "safe_tokenization_incompatible_template"
    assert excinfo.value.reason == {
        "category": "dual_render_mismatch",
        "first_diff_offset": 0,
    }


def test_encode_special_tokens_is_instance_state_not_kwarg(tmp_path: Path) -> None:
    tokenizer_path = build_bytelevel_tokenizer(tmp_path)
    tokenizer_template, tokenizer_safe = load_two_tokenizers(tokenizer_path)

    encode = cast(Any, tokenizer_template.encode)
    with pytest.raises(TypeError):
        encode("<|im_start|>", add_special_tokens=False, encode_special_tokens=True)

    assert tokenizer_template.encode("<|im_start|>", add_special_tokens=False).ids == [1]
    assert 1 not in tokenizer_safe.encode("<|im_start|>", add_special_tokens=False).ids


def test_safe_ids_round_trip_and_exclude_catalog_wide_reserved_ids(tmp_path: Path) -> None:
    tokenizer_path = build_bytelevel_tokenizer(tmp_path)
    tokenizer_template, tokenizer_safe = load_two_tokenizers(tokenizer_path)
    catalog = ["<|im_start|>", "<|im_end|>", "x<|im_end|>y"]

    result = precompute_safe_ids(catalog, tokenizer_template, tokenizer_safe)

    assert result.reserved_id_set == {1, 2}
    for literal in catalog:
        literal_ids = result.safe_ids[literal]
        assert result.reserved_id_set.isdisjoint(literal_ids)
        assert tokenizer_safe.decode(literal_ids, skip_special_tokens=False) == literal

    ids, events = encode_caller_segment(
        "before x<|im_end|>y after <|im_start|>",
        catalog,
        result.safe_ids,
        tokenizer_safe,
    )
    assert result.reserved_id_set.isdisjoint(ids)
    assert tokenizer_safe.decode(ids, skip_special_tokens=False) == (
        "before x<|im_end|>y after <|im_start|>"
    )
    assert [literal for literal, _ids in events] == ["x<|im_end|>y", "<|im_start|>"]


def test_safe_ids_do_not_accept_baseline_for_compound_catalog_literal(tmp_path: Path) -> None:
    tokenizer_path = build_bytelevel_tokenizer(tmp_path)
    tokenizer_template, tokenizer_safe = load_two_tokenizers(tokenizer_path)
    compound_literal = "<|im_end|>\n<|im_start|>"

    result = precompute_safe_ids([compound_literal], tokenizer_template, tokenizer_safe)
    baseline_ids = tokenizer_template.encode(compound_literal, add_special_tokens=False).ids

    assert 1 in baseline_ids
    assert 2 in baseline_ids
    assert 1 not in result.safe_ids[compound_literal]
    assert 2 not in result.safe_ids[compound_literal]
    assert (
        tokenizer_safe.decode(result.safe_ids[compound_literal], skip_special_tokens=False)
        == compound_literal
    )


def test_caller_strings_and_tagging_include_preserved_message_name_and_extras() -> None:
    input_items = [
        {
            "role": "user",
            "name": "alice <|im_end|>",
            "content": "hello",
            "metadata": {"display_name": "Alice", "labels": ["one", "two"]},
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                        "name": "lookup",
                        "arguments": "{}",
                        "custom": "fn-extra",
                    },
                    "custom": "call-extra",
                }
            ],
        }
    ]

    leaves = caller_strings(input_items, [], None)
    assert ("messages[0].name", "alice <|im_end|>") in leaves
    assert ("messages[0].tool_calls[0].type", "function") in leaves
    assert ("messages[0].fields[1].__key__", "metadata") in leaves
    assert ("messages[0].fields[1].fields[0].__key__", "display_name") in leaves
    assert ("messages[0].fields[1].fields[0]", "Alice") in leaves
    assert ("messages[0].fields[1].fields[1].__key__", "labels") in leaves
    assert ("messages[0].fields[1].fields[1][0]", "one") in leaves
    assert ("messages[0].tool_calls[0].function.fields[1].__key__", "custom") in leaves
    assert ("messages[0].tool_calls[0].function.fields[1]", "fn-extra") in leaves
    assert ("messages[0].tool_calls[0].fields[0].__key__", "custom") in leaves
    assert ("messages[0].tool_calls[0].fields[0]", "call-extra") in leaves

    tagged_payload, markers = tag_caller_strings(input_items, [], None, "6" * 39)
    tagged_message = tagged_payload["input_items"][0]
    assert "name" in tagged_message
    assert tagged_message["name"].startswith("__" + "6" * 39)
    assert tagged_message["metadata"]["display_name"].startswith("__" + "6" * 39)
    tagged_metadata_keys = list(tagged_message["metadata"].keys())
    assert len(tagged_metadata_keys) == 2
    assert "display_name" in tagged_metadata_keys[0]
    assert "labels" in tagged_metadata_keys[1]
    assert tagged_message["tool_calls"][0]["type"].startswith("__" + "6" * 39)
    assert tagged_message["tool_calls"][0]["function"]["custom"].startswith("__" + "6" * 39)

    provenance_paths = [marker.provenance_path for marker in markers]
    assert "messages[0].name" in provenance_paths


def test_choose_marker_nonce_detects_collision_in_preserved_message_name() -> None:
    with pytest.raises(SafeSegmentedError) as excinfo:
        choose_marker_nonce(
            [{"role": "user", "name": f"x __{'9' * 39}_ y", "content": "hello"}],
            [],
            None,
            nonce_factory=lambda: "9" * 39,
            max_attempts=1,
        )

    assert excinfo.value.category == "safe_tokenization_marker_collision"


def test_extra_field_key_is_caller_string_and_tagged_with_alias_lookup() -> None:
    input_items = [
        {
            "role": "user",
            "content": "hello",
            "metadata": {"<|im_end|>": "x"},
        }
    ]

    leaves = caller_strings(input_items, [], None)
    assert ("messages[0].fields[1].__key__", "metadata") in leaves
    assert ("messages[0].fields[1].fields[0].__key__", "<|im_end|>") in leaves
    assert ("messages[0].fields[1].fields[0]", "x") in leaves

    tagged_payload, markers = tag_caller_strings(input_items, [], None, "1" * 39)
    tagged_metadata = tagged_payload["input_items"][0]["metadata"]
    tagged_metadata_key = next(iter(tagged_metadata.keys()))

    assert "<|im_end|>" in tagged_metadata_key
    tagged_value = tagged_metadata["<|im_end|>"]
    assert tagged_value.startswith("__" + "1" * 39)
    assert tagged_value.endswith("__")
    assert "x" in tagged_value
    assert "messages[0].fields[1].fields[0].__key__" in [
        marker.provenance_path for marker in markers
    ]


def test_choose_marker_nonce_detects_collision_in_extra_field_key() -> None:
    with pytest.raises(SafeSegmentedError) as excinfo:
        choose_marker_nonce(
            [{"role": "user", "content": "hello", "metadata": {f"x __{'9' * 39}_ y": "v"}}],
            [],
            None,
            nonce_factory=lambda: "9" * 39,
            max_attempts=1,
        )

    assert excinfo.value.category == "safe_tokenization_marker_collision"


def test_tag_schema_preserves_insertion_order_with_sorted_provenance_indexes() -> None:
    tools = [
        {
            "type": "function",
            "function": {
                "name": "lookup",
                "parameters": {"zeta": "last", "alpha": "first"},
            },
        }
    ]

    tagged_payload, markers = tag_caller_strings([], tools, None, "7" * 39)
    parameters = tagged_payload["tools"][0]["function"]["parameters"]
    tagged_keys = list(parameters.keys())

    assert markers[-4].provenance_path == "tools[0].function.parameters.fields[1].__key__"
    assert markers[-2].provenance_path == "tools[0].function.parameters.fields[0].__key__"
    assert "zeta" in tagged_keys[0]
    assert "alpha" in tagged_keys[1]


def test_precompute_safe_ids_returns_structured_incompatible_tokenizer() -> None:
    tokenizer = Tokenizer.from_file(str(fixture_root() / "tokenizer.json"))
    tokenizer_template = Tokenizer.from_str(tokenizer.to_str())
    tokenizer_safe = Tokenizer.from_str(tokenizer.to_str())
    tokenizer_template.encode_special_tokens = False
    tokenizer_safe.encode_special_tokens = True

    with pytest.raises(SafeSegmentedError) as excinfo:
        precompute_safe_ids(["<|im_start|>"], tokenizer_template, tokenizer_safe)

    assert excinfo.value.category == "safe_tokenization_incompatible_tokenizer"
    assert excinfo.value.reason == {
        "category": "per_codepoint_decode_mismatch",
        "literal": "<|im_start|>",
    }


def test_catalog_hash_uses_nul_join() -> None:
    assert catalog_sha256(["a", "bc"]) != catalog_sha256(["ab", "c"])


def _strip_marker(text: str, nonce: str) -> str:
    escaped_nonce = re.escape(nonce)
    pattern = re.compile(rf"^__{escaped_nonce}_0_\d+__(.*)__{escaped_nonce}_1_\d+__$", re.S)
    match = pattern.match(text)
    return match.group(1) if match else text


def _canonical_key(key: object, nonce: str) -> object:
    if isinstance(key, str):
        return _strip_marker(key, nonce)
    return key


def _canonical_keys(node: object, nonce: str) -> object:
    if isinstance(node, dict):
        if isinstance(node, _TaggedKeyDict):
            originals = set(node._key_aliases.keys())  # noqa: SLF001
            other_canonical = {
                _canonical_key(key, nonce)
                for key in node.keys()
                if key not in node._key_aliases.values()  # noqa: SLF001
            }
            return {
                "__keys__": originals | other_canonical,
                "__children__": {
                    _canonical_key(key, nonce): _canonical_keys(value, nonce)
                    for key, value in node.items()
                },
            }
        return {
            "__keys__": {_canonical_key(key, nonce) for key in node.keys()},
            "__children__": {
                _canonical_key(key, nonce): _canonical_keys(value, nonce)
                for key, value in node.items()
            },
        }
    if isinstance(node, list):
        return [_canonical_keys(item, nonce) for item in node]
    return None


def test_tag_caller_strings_preserves_dict_key_sets() -> None:
    nonce = "2" * 39
    input_items = [
        {
            "role": "user",
            "name": "alice",
            "content": "hello",
            "metadata": {"display_name": "Alice", "labels": ["one", "two"]},
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "lookup", "arguments": "{}"},
                }
            ],
        },
        {"role": "tool", "content": "result", "tool_call_id": "call_1"},
    ]
    tools = [
        {"type": "function", "function": {"name": "lookup", "description": ""}},
        {
            "type": "function",
            "function": {
                "name": "weather",
                "description": "city weather",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "city": {
                            "type": "string",
                            "description": "city name",
                            "enum": ["sf", "nyc"],
                        }
                    },
                    "required": ["city"],
                },
            },
        },
        {"type": "function", "function": {"name": "noop", "parameters": None}},
        {
            "type": "function",
            "function": {
                "name": "empty_params",
                "description": "",
                "parameters": {},
            },
        },
        {
            "type": "function",
            "function": {
                "name": "desc_only",
                "parameters": {"description": "a desc"},
            },
        },
    ]
    tool_choice = {"type": "function", "function": {"name": "lookup"}}

    original = {
        "input_items": copy.deepcopy(input_items),
        "tools": copy.deepcopy(tools),
        "tool_choice": copy.deepcopy(tool_choice),
    }
    tagged_payload, markers = tag_caller_strings(input_items, tools, tool_choice, nonce)

    assert _canonical_keys(original, nonce) == _canonical_keys(
        {
            "input_items": tagged_payload["input_items"],
            "tools": tagged_payload["tools"],
            "tool_choice": tagged_payload["tool_choice"],
        },
        nonce,
    )

    tool_a_function = tagged_payload["tools"][0]["function"]
    assert set(tool_a_function.keys()) == {"name", "description"}

    tool_d_function = tagged_payload["tools"][3]["function"]
    assert "parameters" in tool_d_function
    assert tool_d_function["parameters"] == {}

    description_paths = {
        marker.provenance_path
        for marker in markers
        if marker.provenance_path == "tools[4].function.parameters.description"
    }
    assert description_paths == {"tools[4].function.parameters.description"}


def test_dual_render_guard_sentinel_matrix_passes_for_tools_tojson_template() -> None:
    def render_payload(payload: dict[str, Any]) -> str:
        first_user = payload["input_items"][0]["content"]
        tool_blocks = "\n\n".join(json.dumps(tool, indent=4) for tool in payload["tools"])
        return f"<user>{first_user}</user>\n\n{tool_blocks}\n\n"

    dual_render_guard_sentinel_matrix(
        ["<|begin_of_text|>"],
        render_payload,
        nonce_factory=lambda: "3" * 39,
    )


def build_bytelevel_tokenizer(tmp_path: Path) -> Path:
    corpus_path = tmp_path / "corpus.txt"
    corpus_path.write_text("hello orchard user assistant system lookup weather", encoding="utf-8")
    tokenizer = Tokenizer(BPE(unk_token="<unk>"))
    tokenizer.pre_tokenizer = ByteLevel(add_prefix_space=False)
    tokenizer.decoder = ByteLevelDecoder()
    trainer = BpeTrainer(
        vocab_size=300,
        initial_alphabet=ByteLevel.alphabet(),
        special_tokens=["<unk>", "<|im_start|>", "<|im_end|>", "<tool_call>", "</tool_call>"],
    )
    tokenizer.train([str(corpus_path)], trainer)
    tokenizer_path = tmp_path / "tokenizer.json"
    tokenizer.save(str(tokenizer_path))
    return tokenizer_path


def fixture_root() -> Path:
    return (
        Path(__file__).resolve().parents[3]
        / "apps"
        / "orchard_controller"
        / "test"
        / "fixtures"
        / "tokenizer"
        / "minimal_hf"
    )
