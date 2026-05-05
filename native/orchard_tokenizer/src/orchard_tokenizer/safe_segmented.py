from __future__ import annotations

import copy
import hashlib
import uuid
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, TypeAlias, cast

from tokenizers import Tokenizer

SegmentKind: TypeAlias = Literal["template", "caller"]
CatalogPartKind: TypeAlias = Literal["between", "literal"]

_SCHEMA_NAMED_COLLECTIONS = frozenset(
    {"$defs", "definitions", "dependentSchemas", "patternProperties", "properties"}
)
_SCHEMA_KEYWORDS = frozenset(
    {
        "$defs",
        "additionalItems",
        "additionalProperties",
        "allOf",
        "anyOf",
        "const",
        "contains",
        "default",
        "definitions",
        "dependentSchemas",
        "description",
        "else",
        "enum",
        "examples",
        "exclusiveMaximum",
        "exclusiveMinimum",
        "format",
        "if",
        "items",
        "maximum",
        "maxItems",
        "maxLength",
        "maxProperties",
        "minimum",
        "minItems",
        "minLength",
        "minProperties",
        "multipleOf",
        "not",
        "oneOf",
        "pattern",
        "patternProperties",
        "prefixItems",
        "properties",
        "propertyNames",
        "required",
        "then",
        "title",
        "type",
        "unevaluatedItems",
        "unevaluatedProperties",
    }
)

_MESSAGE_KNOWN_FIELDS = frozenset({"role", "name", "content", "tool_calls", "tool_call_id"})
_TOOL_CALL_KNOWN_FIELDS = frozenset({"id", "type", "function"})
_TOOL_CALL_FUNCTION_KNOWN_FIELDS = frozenset({"name", "arguments"})
_TOOL_KNOWN_FIELDS = frozenset({"type", "function"})
_TOOL_FUNCTION_KNOWN_FIELDS = frozenset({"name", "description", "parameters"})
_TOOL_CHOICE_KNOWN_FIELDS = frozenset({"type", "function"})
_TOOL_CHOICE_FUNCTION_KNOWN_FIELDS = frozenset({"name"})


@dataclass(frozen=True, slots=True)
class MarkerPair:
    index: int
    begin: str
    end: str
    provenance_path: str


@dataclass(frozen=True, slots=True)
class RenderedSegment:
    kind: SegmentKind
    text: str
    provenance_path: str | None = None
    marker_index: int | None = None


@dataclass(frozen=True, slots=True)
class SafeIdsResult:
    safe_ids: dict[str, list[int]]
    reserved_id_set: set[int]
    reserved_ids: dict[str, int | None]


@dataclass(frozen=True, slots=True)
class SafeEncodingEvent:
    provenance_path: str | None
    literal: str
    segment_index: int
    safe_ids_len: int


class SafeSegmentedError(Exception):
    def __init__(
        self,
        category: str,
        message: str,
        *,
        reason: dict[str, Any] | None = None,
        literal: str | None = None,
    ) -> None:
        super().__init__(message)
        self.category = category
        self.reason = reason
        self.literal = literal


class _TaggedKeyDict(dict[Any, Any]):
    def __init__(self, values: dict[Any, Any], key_aliases: dict[str, str]) -> None:
        super().__init__(values)
        self._key_aliases = key_aliases

    def _resolve_key(self, key: Any) -> Any:
        if super().__contains__(key):
            return key
        if isinstance(key, str):
            return self._key_aliases.get(key, key)
        return key

    def __getitem__(self, key: Any) -> Any:
        return super().__getitem__(self._resolve_key(key))

    def get(self, key: Any, default: Any = None) -> Any:
        return super().get(self._resolve_key(key), default)

    def __contains__(self, key: object) -> bool:
        if super().__contains__(key):
            return True
        if isinstance(key, str):
            return super().__contains__(self._key_aliases.get(key, key))
        return False

    def copy(self) -> _TaggedKeyDict:
        return _TaggedKeyDict(dict(self), dict(self._key_aliases))


def make_request_nonce() -> str:
    return str(uuid.uuid4().int).zfill(39)


def tag_begin(nonce: str, index: int) -> str:
    return f"__{nonce}_0_{index}__"


def tag_end(nonce: str, index: int) -> str:
    return f"__{nonce}_1_{index}__"


def marker_prefix(nonce: str) -> str:
    return f"__{nonce}_"


def catalog_sha256(control_tokens: Sequence[str]) -> str:
    return hashlib.sha256("\0".join(control_tokens).encode("utf-8")).hexdigest()


def caller_strings(input_items: Any, tools: Any, tool_choice: Any) -> list[tuple[str, str]]:
    return _message_strings(input_items) + _tool_strings(tools) + _tool_choice_strings(tool_choice)


def choose_marker_nonce(
    input_items: Any,
    tools: Any,
    tool_choice: Any,
    *,
    nonce_factory: Callable[[], str] = make_request_nonce,
    max_attempts: int = 5,
) -> str:
    leaves = caller_strings(input_items, tools, tool_choice)

    for _attempt in range(max_attempts):
        nonce = nonce_factory()
        if not _marker_collision(marker_prefix(nonce), leaves):
            return nonce

    raise SafeSegmentedError(
        "safe_tokenization_marker_collision",
        "safe tokenization markers collided with caller-authored content",
        reason={"category": "marker_collision", "max_attempts": max_attempts},
    )


def tag_caller_strings(
    input_items: Any,
    tools: Any,
    tool_choice: Any,
    nonce: str,
) -> tuple[dict[str, Any], list[MarkerPair]]:
    marker_pairs: list[MarkerPair] = []

    def wrap(path: str, value: str) -> str:
        index = len(marker_pairs)
        begin = tag_begin(nonce, index)
        end = tag_end(nonce, index)
        marker_pairs.append(MarkerPair(index, begin, end, path))
        return f"{begin}{value}{end}"

    tagged_input_items = _tag_messages(copy.deepcopy(input_items), wrap)
    tagged_tools = _tag_tools(copy.deepcopy(tools), wrap)
    tagged_tool_choice = _tag_tool_choice(copy.deepcopy(tool_choice), wrap)

    return (
        {
            "input_items": tagged_input_items,
            "tools": tagged_tools,
            "tool_choice": tagged_tool_choice,
        },
        marker_pairs,
    )


def strip_markers(rendered: str, marker_pairs: Sequence[MarkerPair]) -> str:
    return "".join(segment.text for segment in walk_rendered(rendered, marker_pairs))


def walk_rendered(rendered: str, marker_pairs: Sequence[MarkerPair]) -> list[RenderedSegment]:
    begin_markers = {pair.begin: pair for pair in marker_pairs}
    end_markers = {pair.end for pair in marker_pairs}
    segments: list[RenderedSegment] = []
    position = 0

    while position < len(rendered):
        next_begin, pair = _find_next_marker(rendered, position, begin_markers)
        next_end, _end_marker = _find_next_string(rendered, position, end_markers)

        if next_end != -1 and (next_begin == -1 or next_end < next_begin):
            raise SafeSegmentedError(
                "safe_tokenization_incompatible_template",
                "rendered prompt contains an unmatched safe-tokenization end marker",
                reason={"category": "marker_walk_mismatch"},
            )

        if next_begin == -1 or pair is None:
            _append_segment(segments, "template", rendered[position:])
            break

        _append_segment(segments, "template", rendered[position:next_begin])
        caller_start = next_begin + len(pair.begin)
        caller_end = rendered.find(pair.end, caller_start)
        if caller_end == -1:
            raise SafeSegmentedError(
                "safe_tokenization_incompatible_template",
                "rendered prompt is missing a safe-tokenization end marker",
                reason={
                    "category": "marker_walk_mismatch",
                    "leaf_class": pair.provenance_path,
                },
            )

        nested_begin, _nested_pair = _find_next_marker(rendered, caller_start, begin_markers)
        if nested_begin != -1 and nested_begin < caller_end:
            raise SafeSegmentedError(
                "safe_tokenization_incompatible_template",
                "rendered prompt contains nested safe-tokenization markers",
                reason={
                    "category": "marker_walk_mismatch",
                    "leaf_class": pair.provenance_path,
                },
            )

        segments.append(
            RenderedSegment(
                "caller",
                rendered[caller_start:caller_end],
                pair.provenance_path,
                pair.index,
            )
        )
        position = caller_end + len(pair.end)

    if position == len(rendered):
        _append_segment(segments, "template", "")

    return segments


def split_segment_around_catalog(
    segment_text: str,
    catalog: Sequence[str],
) -> list[tuple[CatalogPartKind, str]]:
    literals = sorted(
        {literal for literal in catalog if literal}, key=lambda item: (-len(item), item)
    )
    parts: list[tuple[CatalogPartKind, str]] = []
    position = 0
    between_start = 0

    while position < len(segment_text):
        match = next(
            (literal for literal in literals if segment_text.startswith(literal, position)), None
        )
        if match is None:
            position += 1
            continue

        if between_start < position:
            parts.append(("between", segment_text[between_start:position]))
        parts.append(("literal", match))
        position += len(match)
        between_start = position

    if between_start < len(segment_text):
        parts.append(("between", segment_text[between_start:]))

    if not parts:
        parts.append(("between", ""))

    return parts


def load_two_tokenizers(tokenizer_path: Path) -> tuple[Tokenizer, Tokenizer]:
    template_tokenizer = Tokenizer.from_file(str(tokenizer_path))
    safe_tokenizer = Tokenizer.from_file(str(tokenizer_path))
    template_tokenizer.encode_special_tokens = False
    safe_tokenizer.encode_special_tokens = True
    return template_tokenizer, safe_tokenizer


def precompute_safe_ids(
    catalog: Sequence[str],
    tokenizer_template: Tokenizer,
    tokenizer_safe: Tokenizer,
) -> SafeIdsResult:
    baseline_ids: dict[str, list[int]] = {}
    reserved_ids: dict[str, int | None] = {}

    for literal in catalog:
        if literal == "":
            _raise_tokenizer_incompatible(literal, "empty_literal")

        ids = list(tokenizer_template.encode(literal, add_special_tokens=False).ids)
        if not ids:
            _raise_tokenizer_incompatible(literal, "empty_literal")

        baseline_ids[literal] = ids
        reserved_ids[literal] = ids[0] if len(ids) == 1 else None

    reserved_id_set = {
        reserved_id for reserved_id in reserved_ids.values() if reserved_id is not None
    }
    safe_ids: dict[str, list[int]] = {}

    for literal in catalog:
        own_reserved_id = reserved_ids[literal]
        candidate = list(tokenizer_safe.encode(literal, add_special_tokens=False).ids)
        if _safe_candidate_valid(
            tokenizer_safe,
            candidate,
            literal,
            own_reserved_id,
            reserved_id_set,
        ):
            safe_ids[literal] = candidate
            continue

        fallback = _per_codepoint_ids(literal, tokenizer_safe)
        if _safe_candidate_valid(
            tokenizer_safe,
            fallback,
            literal,
            own_reserved_id,
            reserved_id_set,
        ):
            safe_ids[literal] = fallback
            continue

        _raise_tokenizer_incompatible(
            literal,
            _candidate_failure_category(
                tokenizer_safe,
                fallback,
                literal,
                own_reserved_id,
                reserved_id_set,
            ),
        )

    return SafeIdsResult(safe_ids, reserved_id_set, reserved_ids)


def dual_render_guard(
    baseline_render: str,
    tagged_render: str,
    marker_pairs: Sequence[MarkerPair],
    *,
    leaf_class: str | None = None,
    sentinel_index: int | None = None,
) -> None:
    stripped = strip_markers(tagged_render, marker_pairs)
    if stripped == baseline_render:
        return

    reason: dict[str, Any] = {
        "category": "dual_render_mismatch",
        "first_diff_offset": first_diff_offset(stripped, baseline_render),
    }
    if leaf_class is not None:
        reason["leaf_class"] = leaf_class
    if sentinel_index is not None:
        reason["sentinel_index"] = sentinel_index

    raise SafeSegmentedError(
        "safe_tokenization_incompatible_template",
        "tagged chat-template render differs from untagged render after marker removal",
        reason=reason,
    )


def first_diff_offset(left: str, right: str) -> int:
    for index, (left_char, right_char) in enumerate(zip(left, right, strict=False)):
        if left_char != right_char:
            return index
    return min(len(left), len(right))


def encode_caller_segment(
    text: str,
    catalog: Sequence[str],
    safe_ids: Mapping[str, Sequence[int]],
    tokenizer_safe: Tokenizer,
) -> tuple[list[int], list[tuple[str, list[int]]]]:
    ids: list[int] = []
    literal_events: list[tuple[str, list[int]]] = []

    for kind, value in split_segment_around_catalog(text, catalog):
        if kind == "between":
            ids.extend(tokenizer_safe.encode(value, add_special_tokens=False).ids)
            continue

        literal_ids = list(safe_ids[value])
        ids.extend(literal_ids)
        literal_events.append((value, literal_ids))

    return ids, literal_events


def encode_rendered_segments(
    segments: Sequence[RenderedSegment],
    catalog: Sequence[str],
    safe_ids: Mapping[str, Sequence[int]],
    tokenizer_template: Tokenizer,
    tokenizer_safe: Tokenizer,
    *,
    max_events: int = 50,
) -> tuple[str, list[int], list[SafeEncodingEvent]]:
    rendered_prompt_parts: list[str] = []
    prompt_token_ids: list[int] = []
    events: list[SafeEncodingEvent] = []

    for segment_index, segment in enumerate(segments):
        rendered_prompt_parts.append(segment.text)
        if segment.kind == "template":
            prompt_token_ids.extend(
                tokenizer_template.encode(segment.text, add_special_tokens=False).ids
            )
            continue

        caller_ids, literal_events = encode_caller_segment(
            segment.text,
            catalog,
            safe_ids,
            tokenizer_safe,
        )
        prompt_token_ids.extend(caller_ids)
        for literal, literal_ids in literal_events:
            if len(events) >= max_events:
                continue
            events.append(
                SafeEncodingEvent(
                    segment.provenance_path,
                    literal,
                    segment_index,
                    len(literal_ids),
                )
            )

    return "".join(rendered_prompt_parts), prompt_token_ids, events


def dual_render_guard_sentinel_matrix(
    catalog: Sequence[str],
    render_payload: Callable[[dict[str, Any]], str],
    *,
    nonce_factory: Callable[[], str] = make_request_nonce,
) -> None:
    for leaf_class, sentinel_index, payload in sentinel_payloads(catalog):
        nonce = choose_marker_nonce(
            payload["input_items"],
            payload["tools"],
            payload["tool_choice"],
            nonce_factory=nonce_factory,
        )
        tagged_payload, marker_pairs = tag_caller_strings(
            payload["input_items"], payload["tools"], payload["tool_choice"], nonce
        )
        dual_render_guard(
            render_payload(payload),
            render_payload(tagged_payload),
            marker_pairs,
            leaf_class=leaf_class,
            sentinel_index=sentinel_index,
        )


def sentinel_payloads(catalog: Sequence[str]) -> list[tuple[str, int, dict[str, Any]]]:
    catalog_literal = catalog[0] if catalog else "<|catalog_literal|>"
    sentinels = [
        "",
        "hello",
        "hello world",
        "she said \"hi\" and 'bye'",
        "path\\to\\file",
        "line1\nline2\t\n",
        "héllo wörld 🌍",
        catalog_literal,
        "lorem ipsum " * 80,
    ]
    payloads: list[tuple[str, int, dict[str, Any]]] = []

    for index, value in enumerate(sentinels):
        payloads.append(
            (
                "messages[0].content",
                index,
                {
                    "input_items": [{"role": "user", "content": value}],
                    "tools": [],
                    "tool_choice": None,
                },
            )
        )
        payloads.append(
            (
                "tools[0].function.description",
                index,
                {
                    "input_items": [{"role": "user", "content": "hello"}],
                    "tools": [
                        {
                            "type": "function",
                            "function": {"name": "lookup", "description": value},
                        }
                    ],
                    "tool_choice": None,
                },
            )
        )
        payloads.append(
            (
                "tools[0].function.parameters.description",
                index,
                {
                    "input_items": [{"role": "user", "content": "hello"}],
                    "tools": [
                        {
                            "type": "function",
                            "function": {
                                "name": "lookup",
                                "parameters": {"type": "object", "description": value},
                            },
                        }
                    ],
                    "tool_choice": None,
                },
            )
        )

    return payloads


def _message_strings(input_items: Any) -> list[tuple[str, str]]:
    if not isinstance(input_items, list):
        return []

    strings: list[tuple[str, str]] = []
    for index, item in enumerate(input_items):
        if isinstance(item, dict):
            item_map = cast(dict[str, Any], item)
            strings.extend(_message_item_strings(item_map, index))
    return strings


def _message_item_strings(item: Mapping[str, Any], index: int) -> list[tuple[str, str]]:
    strings: list[tuple[str, str]] = []
    role = item.get("role")
    if isinstance(role, str):
        strings.append((f"messages[{index}].role", role))

    name = item.get("name")
    if isinstance(name, str):
        strings.append((f"messages[{index}].name", name))

    content = item.get("content")
    if isinstance(content, str):
        strings.append((f"messages[{index}].content", content))
    elif isinstance(content, list):
        for part_index, part in enumerate(content):
            if isinstance(part, dict):
                part_map = cast(dict[str, Any], part)
                text = part_map.get("text")
                if isinstance(text, str):
                    strings.append((f"messages[{index}].content[{part_index}].text", text))

    tool_calls = item.get("tool_calls")
    if isinstance(tool_calls, list):
        for call_index, tool_call in enumerate(tool_calls):
            if isinstance(tool_call, dict):
                tool_call_map = cast(dict[str, Any], tool_call)
                call_base = f"messages[{index}].tool_calls[{call_index}]"
                function = tool_call_map.get("function")
                _append_string_field(strings, tool_call_map, "id", call_base)
                _append_string_field(strings, tool_call_map, "type", call_base)
                if isinstance(function, dict):
                    function_map = cast(dict[str, Any], function)
                    function_base = f"{call_base}.function"
                    _append_string_field(strings, function_map, "name", function_base)
                    _append_string_field(strings, function_map, "arguments", function_base)
                    strings.extend(
                        _extra_string_values(
                            function_map,
                            function_base,
                            known_fields=_TOOL_CALL_FUNCTION_KNOWN_FIELDS,
                        )
                    )
                strings.extend(
                    _extra_string_values(
                        tool_call_map, call_base, known_fields=_TOOL_CALL_KNOWN_FIELDS
                    )
                )

    tool_call_id = item.get("tool_call_id")
    if isinstance(tool_call_id, str):
        strings.append((f"messages[{index}].tool_call_id", tool_call_id))

    strings.extend(
        _extra_string_values(item, f"messages[{index}]", known_fields=_MESSAGE_KNOWN_FIELDS)
    )

    return strings


def _tool_strings(tools: Any) -> list[tuple[str, str]]:
    if not isinstance(tools, list):
        return []

    strings: list[tuple[str, str]] = []
    for index, tool in enumerate(tools):
        if not isinstance(tool, dict):
            continue
        tool_map = cast(dict[str, Any], tool)
        function = tool_map.get("function")
        base = f"tools[{index}]"
        _append_string_field(strings, tool_map, "type", base)
        if isinstance(function, dict):
            function_map = cast(dict[str, Any], function)
            function_base = f"{base}.function"
            _append_string_field(strings, function_map, "name", function_base)
            _append_string_field(strings, function_map, "description", function_base)
            strings.extend(
                _schema_strings(function_map.get("parameters"), f"{function_base}.parameters")
            )
            strings.extend(
                _extra_string_values(
                    function_map,
                    function_base,
                    known_fields=_TOOL_FUNCTION_KNOWN_FIELDS,
                )
            )
        strings.extend(_extra_string_values(tool_map, base, known_fields=_TOOL_KNOWN_FIELDS))
    return strings


def _tool_choice_strings(tool_choice: Any) -> list[tuple[str, str]]:
    if isinstance(tool_choice, str):
        return [("tool_choice", tool_choice)]
    if not isinstance(tool_choice, dict):
        return []

    strings: list[tuple[str, str]] = []
    tool_choice_map = cast(dict[str, Any], tool_choice)
    _append_string_field(strings, tool_choice_map, "type", "tool_choice")
    function = tool_choice_map.get("function")
    if isinstance(function, dict):
        function_map = cast(dict[str, Any], function)
        _append_string_field(strings, function_map, "name", "tool_choice.function")
        strings.extend(
            _extra_string_values(
                function_map,
                "tool_choice.function",
                known_fields=_TOOL_CHOICE_FUNCTION_KNOWN_FIELDS,
            )
        )
    strings.extend(
        _extra_string_values(tool_choice_map, "tool_choice", known_fields=_TOOL_CHOICE_KNOWN_FIELDS)
    )
    return strings


def _schema_strings(value: Any, path: str, key_context: str | None = None) -> list[tuple[str, str]]:
    if isinstance(value, dict):
        strings: list[tuple[str, str]] = []
        for index, (raw_key, child_value) in enumerate(_schema_entries(value)):
            strings.extend(_schema_entry_strings(raw_key, child_value, path, index))
        return strings

    if key_context == "enum" and isinstance(value, list):
        return _indexed_strings(value, path)

    if isinstance(value, str):
        return [(path, value)]

    if isinstance(value, list):
        strings = []
        for index, child_value in enumerate(value):
            strings.extend(_schema_strings(child_value, f"{path}[{index}]", key_context))
        return strings

    return []


def _schema_entry_strings(raw_key: Any, value: Any, path: str, index: int) -> list[tuple[str, str]]:
    key = _key_name(raw_key)
    child_path = _schema_child_path(path, key, index)

    if key in {"description", "title"} and isinstance(value, str):
        return [(child_path, value)]
    if key == "enum" and isinstance(value, list):
        return _indexed_strings(value, child_path)
    if key in _SCHEMA_NAMED_COLLECTIONS and isinstance(value, dict):
        return _named_schema_collection_strings(value, child_path)
    if key == "required" and isinstance(value, list):
        return _indexed_strings(value, child_path)

    strings: list[tuple[str, str]] = []
    if key not in _SCHEMA_KEYWORDS and isinstance(raw_key, str):
        strings.append((f"{child_path}.__key__", raw_key))
    strings.extend(_schema_strings(value, child_path, key))
    return strings


def _named_schema_collection_strings(
    schemas: Mapping[Any, Any], path: str
) -> list[tuple[str, str]]:
    strings: list[tuple[str, str]] = []
    for index, (raw_key, value) in enumerate(_schema_entries(schemas)):
        child_path = f"{path}[{index}]"
        if isinstance(raw_key, str):
            strings.append((f"{child_path}.__key__", raw_key))
        strings.extend(_schema_strings(value, child_path))
    return strings


def _indexed_strings(values: Sequence[Any], path: str) -> list[tuple[str, str]]:
    return [
        (f"{path}[{index}]", value) for index, value in enumerate(values) if isinstance(value, str)
    ]


def _extra_string_values(
    value: Any,
    path: str,
    *,
    known_fields: frozenset[str] | None = None,
) -> list[tuple[str, str]]:
    if isinstance(value, str):
        return [(path, value)]
    if isinstance(value, list):
        strings: list[tuple[str, str]] = []
        for index, child_value in enumerate(value):
            strings.extend(_extra_string_values(child_value, f"{path}[{index}]"))
        return strings
    if isinstance(value, dict):
        strings = []
        sorted_entries = _schema_entries(value)
        for index, (raw_key, child_value) in enumerate(sorted_entries):
            key = _key_name(raw_key)
            if known_fields is not None and key in known_fields:
                continue
            child_path = f"{path}.fields[{index}]"
            if isinstance(raw_key, str):
                strings.append((f"{child_path}.__key__", raw_key))
            strings.extend(_extra_string_values(child_value, child_path))
        return strings
    return []


def _tag_extra_string_values(
    value: Any,
    path: str,
    wrap: Callable[[str, str], str],
    *,
    known_fields: frozenset[str] | None = None,
) -> Any:
    if isinstance(value, str):
        return wrap(path, value)
    if isinstance(value, list):
        for index, child_value in enumerate(value):
            value[index] = _tag_extra_string_values(child_value, f"{path}[{index}]", wrap)
        return value
    if isinstance(value, dict):
        sorted_entries = _schema_entries(value)
        entry_indexes = {
            entry_key: index for index, (entry_key, _entry_value) in enumerate(sorted_entries)
        }
        tagged: dict[Any, Any] = {}
        key_aliases: dict[str, str] = {}
        for raw_key, child_value in value.items():
            key = _key_name(raw_key)
            if known_fields is not None and key in known_fields:
                tagged[raw_key] = child_value
                continue
            child_path = f"{path}.fields[{entry_indexes.get(raw_key, 0)}]"
            tagged_key = raw_key
            if isinstance(raw_key, str):
                tagged_key = wrap(f"{child_path}.__key__", raw_key)
                key_aliases[raw_key] = tagged_key
            tagged[tagged_key] = _tag_extra_string_values(child_value, child_path, wrap)
        if key_aliases:
            return _TaggedKeyDict(tagged, key_aliases)
        return tagged
    return value


def _tag_messages(input_items: Any, wrap: Callable[[str, str], str]) -> Any:
    if not isinstance(input_items, list):
        return input_items

    for index, item in enumerate(input_items):
        if isinstance(item, dict):
            item_map = cast(dict[str, Any], item)
            _tag_string_field(item_map, "role", f"messages[{index}]", wrap)
            _tag_string_field(item_map, "name", f"messages[{index}]", wrap)
            _tag_content(item_map, index, wrap)
            _tag_message_tool_calls(item_map, index, wrap)
            tool_call_id = item_map.get("tool_call_id")
            if isinstance(tool_call_id, str):
                item_map["tool_call_id"] = wrap(f"messages[{index}].tool_call_id", tool_call_id)
            input_items[index] = _tag_extra_string_values(
                item_map, f"messages[{index}]", wrap, known_fields=_MESSAGE_KNOWN_FIELDS
            )
    return input_items


def _tag_content(item: dict[str, Any], message_index: int, wrap: Callable[[str, str], str]) -> None:
    content = item.get("content")
    if isinstance(content, str):
        item["content"] = wrap(f"messages[{message_index}].content", content)
        return

    if not isinstance(content, list):
        return

    for part_index, part in enumerate(content):
        if isinstance(part, dict):
            part_map = cast(dict[str, Any], part)
            text = part_map.get("text")
            if isinstance(text, str):
                part_map["text"] = wrap(
                    f"messages[{message_index}].content[{part_index}].text",
                    text,
                )


def _tag_message_tool_calls(
    item: dict[str, Any], message_index: int, wrap: Callable[[str, str], str]
) -> None:
    tool_calls = item.get("tool_calls")
    if not isinstance(tool_calls, list):
        return

    for call_index, tool_call in enumerate(tool_calls):
        if not isinstance(tool_call, dict):
            continue
        tool_call_map = cast(dict[str, Any], tool_call)
        call_base = f"messages[{message_index}].tool_calls[{call_index}]"
        _tag_string_field(tool_call_map, "id", call_base, wrap)
        _tag_string_field(tool_call_map, "type", call_base, wrap)
        function = tool_call_map.get("function")
        if isinstance(function, dict):
            function_map = cast(dict[str, Any], function)
            function_base = f"{call_base}.function"
            _tag_string_field(function_map, "name", function_base, wrap)
            _tag_string_field(function_map, "arguments", function_base, wrap)
            tool_call_map["function"] = _tag_extra_string_values(
                function_map,
                function_base,
                wrap,
                known_fields=_TOOL_CALL_FUNCTION_KNOWN_FIELDS,
            )
        tool_calls[call_index] = _tag_extra_string_values(
            tool_call_map, call_base, wrap, known_fields=_TOOL_CALL_KNOWN_FIELDS
        )


def _tag_tools(tools: Any, wrap: Callable[[str, str], str]) -> Any:
    if not isinstance(tools, list):
        return tools

    for index, tool in enumerate(tools):
        if not isinstance(tool, dict):
            continue
        tool_map = cast(dict[str, Any], tool)
        base = f"tools[{index}]"
        _tag_string_field(tool_map, "type", base, wrap)
        function = tool_map.get("function")
        if isinstance(function, dict):
            function_map = cast(dict[str, Any], function)
            function_base = f"{base}.function"
            _tag_string_field(function_map, "name", function_base, wrap)
            _tag_string_field(function_map, "description", function_base, wrap)
            if "parameters" in function_map:
                function_map["parameters"] = _tag_schema(
                    function_map["parameters"],
                    f"{function_base}.parameters",
                    wrap,
                )
            tool_map["function"] = _tag_extra_string_values(
                function_map,
                function_base,
                wrap,
                known_fields=_TOOL_FUNCTION_KNOWN_FIELDS,
            )
        tools[index] = _tag_extra_string_values(
            tool_map,
            base,
            wrap,
            known_fields=_TOOL_KNOWN_FIELDS,
        )
    return tools


def _tag_tool_choice(tool_choice: Any, wrap: Callable[[str, str], str]) -> Any:
    if isinstance(tool_choice, str):
        return wrap("tool_choice", tool_choice)
    if not isinstance(tool_choice, dict):
        return tool_choice

    tool_choice_map = cast(dict[str, Any], tool_choice)
    _tag_string_field(tool_choice_map, "type", "tool_choice", wrap)
    function = tool_choice_map.get("function")
    if isinstance(function, dict):
        function_map = cast(dict[str, Any], function)
        _tag_string_field(function_map, "name", "tool_choice.function", wrap)
        tool_choice_map["function"] = _tag_extra_string_values(
            function_map,
            "tool_choice.function",
            wrap,
            known_fields=_TOOL_CHOICE_FUNCTION_KNOWN_FIELDS,
        )
    return _tag_extra_string_values(
        tool_choice_map,
        "tool_choice",
        wrap,
        known_fields=_TOOL_CHOICE_KNOWN_FIELDS,
    )


def _tag_schema(
    value: Any,
    path: str,
    wrap: Callable[[str, str], str],
    key_context: str | None = None,
) -> Any:
    if isinstance(value, dict):
        tagged: dict[Any, Any] = {}
        sorted_entries = _schema_entries(value)
        for raw_key, child_value in value.items():
            key = _key_name(raw_key)
            child_path = _schema_child_path(path, key, _schema_entry_index(sorted_entries, raw_key))
            tagged_key = raw_key

            if key in _SCHEMA_NAMED_COLLECTIONS and isinstance(child_value, dict):
                tagged[raw_key] = _tag_named_schema_collection(child_value, child_path, wrap)
                continue
            if key not in _SCHEMA_KEYWORDS and isinstance(raw_key, str):
                tagged_key = wrap(f"{child_path}.__key__", raw_key)

            tagged[tagged_key] = _tag_known_or_nested_schema_value(
                key,
                child_value,
                child_path,
                wrap,
            )
        return tagged

    if key_context == "enum" and isinstance(value, list):
        return _tag_indexed_strings(value, path, wrap)

    if isinstance(value, str):
        return wrap(path, value)

    if isinstance(value, list):
        return [
            _tag_schema(child_value, f"{path}[{index}]", wrap, key_context)
            for index, child_value in enumerate(value)
        ]

    return value


def _tag_known_or_nested_schema_value(
    key: str,
    value: Any,
    path: str,
    wrap: Callable[[str, str], str],
) -> Any:
    if key in {"description", "title"} and isinstance(value, str):
        return wrap(path, value)
    if key == "enum" and isinstance(value, list):
        return _tag_indexed_strings(value, path, wrap)
    if key == "required" and isinstance(value, list):
        return _tag_indexed_strings(value, path, wrap)
    return _tag_schema(value, path, wrap, key)


def _tag_named_schema_collection(
    schemas: Mapping[Any, Any], path: str, wrap: Callable[[str, str], str]
) -> dict[Any, Any]:
    tagged: dict[Any, Any] = {}
    sorted_entries = _schema_entries(schemas)
    for raw_key, value in schemas.items():
        child_path = f"{path}[{_schema_entry_index(sorted_entries, raw_key)}]"
        tagged_key = wrap(f"{child_path}.__key__", raw_key) if isinstance(raw_key, str) else raw_key
        tagged[tagged_key] = _tag_schema(value, child_path, wrap)
    return tagged


def _tag_indexed_strings(
    values: Sequence[Any], path: str, wrap: Callable[[str, str], str]
) -> list[Any]:
    return [
        wrap(f"{path}[{index}]", value) if isinstance(value, str) else value
        for index, value in enumerate(values)
    ]


def _tag_string_field(
    mapping: dict[str, Any], field: str, base_path: str, wrap: Callable[[str, str], str]
) -> None:
    value = mapping.get(field)
    if isinstance(value, str):
        mapping[field] = wrap(f"{base_path}.{field}", value)


def _append_string_field(
    strings: list[tuple[str, str]], mapping: Mapping[str, Any], field: str, base_path: str
) -> None:
    value = mapping.get(field)
    if isinstance(value, str):
        strings.append((f"{base_path}.{field}", value))


def _schema_entries(schema: Mapping[Any, Any]) -> list[tuple[Any, Any]]:
    return sorted(schema.items(), key=lambda item: _key_name(item[0]))


def _schema_entry_index(entries: Sequence[tuple[Any, Any]], raw_key: Any) -> int:
    for index, (entry_key, _value) in enumerate(entries):
        if entry_key == raw_key:
            return index
    return 0


def _schema_child_path(path: str, key: str, index: int) -> str:
    if key in _SCHEMA_KEYWORDS:
        return f"{path}.{key}"
    return f"{path}.fields[{index}]"


def _key_name(key: Any) -> str:
    if isinstance(key, str):
        return key
    return repr(key)


def _marker_collision(prefix: str, leaves: Iterable[tuple[str, str]]) -> bool:
    return any(prefix in value for _path, value in leaves)


def _find_next_marker(
    text: str, position: int, markers: Mapping[str, MarkerPair]
) -> tuple[int, MarkerPair | None]:
    best_position = -1
    best_pair: MarkerPair | None = None
    for marker, pair in markers.items():
        found = text.find(marker, position)
        if found != -1 and (best_position == -1 or found < best_position):
            best_position = found
            best_pair = pair
    return best_position, best_pair


def _find_next_string(text: str, position: int, markers: Iterable[str]) -> tuple[int, str | None]:
    best_position = -1
    best_marker: str | None = None
    for marker in markers:
        found = text.find(marker, position)
        if found != -1 and (best_position == -1 or found < best_position):
            best_position = found
            best_marker = marker
    return best_position, best_marker


def _append_segment(segments: list[RenderedSegment], kind: SegmentKind, text: str) -> None:
    if text == "" and segments:
        return
    if segments and segments[-1].kind == kind and kind == "template":
        previous = segments[-1]
        segments[-1] = RenderedSegment(kind, previous.text + text)
        return
    segments.append(RenderedSegment(kind, text))


def _per_codepoint_ids(literal: str, tokenizer_safe: Tokenizer) -> list[int]:
    ids: list[int] = []
    for codepoint in literal:
        ids.extend(tokenizer_safe.encode(codepoint, add_special_tokens=False).ids)
    return ids


def _safe_candidate_valid(
    tokenizer: Tokenizer,
    candidate: Sequence[int],
    literal: str,
    own_reserved_id: int | None,
    reserved_id_set: set[int],
) -> bool:
    if not candidate:
        return False
    if own_reserved_id is not None and own_reserved_id in candidate:
        return False
    if not reserved_id_set.isdisjoint(candidate):
        return False
    return _ids_round_trip(tokenizer, candidate, literal)


def _ids_round_trip(tokenizer: Tokenizer, ids: Sequence[int], literal: str) -> bool:
    return tokenizer.decode(list(ids), skip_special_tokens=False) == literal


def _candidate_failure_category(
    tokenizer: Tokenizer,
    candidate: Sequence[int],
    literal: str,
    own_reserved_id: int | None,
    reserved_id_set: set[int],
) -> str:
    if own_reserved_id is not None and own_reserved_id in candidate:
        return "reserved_id_persists"
    if not reserved_id_set.isdisjoint(candidate):
        return "reserved_id_set_overlap"
    if not _ids_round_trip(tokenizer, candidate, literal):
        return "per_codepoint_decode_mismatch"
    return "reserved_id_persists"


def _raise_tokenizer_incompatible(literal: str, category: str) -> None:
    raise SafeSegmentedError(
        "safe_tokenization_incompatible_tokenizer",
        "safe tokenization catalog literal cannot be encoded without reserved IDs",
        literal=literal,
        reason={"category": category, "literal": literal},
    )


def event_to_dict(event: SafeEncodingEvent) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "literal": event.literal,
        "segment_index": event.segment_index,
        "safe_ids_len": event.safe_ids_len,
    }
    if event.provenance_path is not None:
        payload["provenance_path"] = event.provenance_path
    return payload


def details_for_error(exc: SafeSegmentedError) -> dict[str, Any]:
    details: dict[str, Any] = {}
    if exc.reason is not None:
        details["reason"] = exc.reason
    if exc.literal is not None:
        details["literal"] = exc.literal
    return details


def as_str_dict_list(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    return [cast(dict[str, Any], item) for item in value if isinstance(item, dict)]
