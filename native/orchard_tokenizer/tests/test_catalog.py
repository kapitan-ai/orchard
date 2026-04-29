from __future__ import annotations

import json
from pathlib import Path

from orchard_tokenizer.catalog import (
    extract_chat_template_literals,
    extract_safe_tokenization_catalog,
    extract_wrapper_tool_markers,
)


def test_extract_chat_template_literals_ignores_jinja_blocks(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text(
        """
        <|im_start|>system
        {{ bos_token }}
        {% if messages %}<ignored>{{ messages[0]['content'] }}{% endif %}
        {# <hidden_comment_token> #}
        <assistant>
        """,
        encoding="utf-8",
    )

    assert extract_chat_template_literals(config_path, template_path) == [
        "<assistant>",
        "<ignored>",
        "<|im_start|>",
    ]


def test_extract_chat_template_literals_includes_xml_tags_with_attributes(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text(
        '<tool_call type="function">{{ content }}</tool_call>',
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result["control_tokens_chat_template"] == [
        "</tool_call>",
        '<tool_call type="function">',
    ]
    assert result["chat_template_literals_count"] == 2


def test_extract_chat_template_literals_includes_closing_tags(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text(
        "<s>{{ messages[0]['content'] }}</s><tool_call>x</tool_call><|im_end|>",
        encoding="utf-8",
    )

    assert extract_chat_template_literals(config_path, template_path) == [
        "</s>",
        "</tool_call>",
        "<s>",
        "<tool_call>",
        "<|im_end|>",
    ]


def test_extract_chat_template_literals_includes_bracket_markers(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("[INST] {{ messages[0]['content'] }} [/INST]", encoding="utf-8")

    assert extract_chat_template_literals(config_path, template_path) == ["[/INST]", "[INST]"]


def test_extract_chat_template_literals_includes_rendered_jinja_string_constants(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text(
        """
        {{ '<|im_start|>' }}
        {{ '</tool_call>' }}
        {% set marker = '<non_rendered_set>' %}
        {% if '<non_rendered_if>' %}{% endif %}
        {{ "[INST]" ~ messages[0]['content'] ~ "[/INST]" }}
        <|im_start|>
        """,
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result["control_tokens_chat_template"] == [
        "</tool_call>",
        "<|im_start|>",
        "[/INST]",
        "[INST]",
    ]
    assert "<non_rendered_set>" not in result["control_tokens_chat_template"]
    assert "<non_rendered_if>" not in result["control_tokens_chat_template"]
    assert result["chat_template_literals_count"] == 5


def test_extract_chat_template_literals_excludes_lookup_key_constants(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("{{ message['<|im_start|>'] }}", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result["control_tokens_chat_template"] == []
    assert result["chat_template_literals_count"] == 0


def test_extract_chat_template_literals_excludes_comparison_constants(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("{{ message.role == '<tool_call>' }}", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result["control_tokens_chat_template"] == []
    assert result["chat_template_literals_count"] == 0


def test_extract_chat_template_literals_excludes_filter_argument_constants(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text(
        "{{ message.content | replace('<|im_start|>', '') }}",
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result["control_tokens_chat_template"] == []
    assert result["chat_template_literals_count"] == 0


def test_extract_wrapper_tool_markers_known_and_unknown() -> None:
    assert extract_wrapper_tool_markers("qwen2") == ["</tool_call>", "<tool_call>"]
    assert extract_wrapper_tool_markers(None) == []
    assert extract_wrapper_tool_markers("unknown_parser") == []


def test_extract_safe_tokenization_catalog_counts_raw_observations_before_dedupe(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("</s></s><tool_call></tool_call>", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {},
        }
    )

    assert result == {
        "control_tokens_chat_template": ["</s>", "</tool_call>", "<tool_call>"],
        "control_tokens_wrapper_tool": [],
        "chat_template_literals_count": 4,
        "wrapper_tool_markers_count": 0,
    }


def test_extract_safe_tokenization_catalog_prefers_chat_template_asset(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text(
        json.dumps({"chat_template": "<from_config_only>"}),
        encoding="utf-8",
    )

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("prefix <|explicit_asset|> suffix", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {
                "tokenizer_config_path": str(config_path),
                "chat_template_path": str(template_path),
            },
            "options": {"tool_parser_type": "qwen2"},
        }
    )

    assert result == {
        "control_tokens_chat_template": ["<|explicit_asset|>"],
        "control_tokens_wrapper_tool": ["</tool_call>", "<tool_call>"],
        "chat_template_literals_count": 1,
        "wrapper_tool_markers_count": 2,
    }


def test_extract_safe_tokenization_catalog_falls_back_to_config_template(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text(
        json.dumps({"chat_template": "alpha <token_a> beta <|token_b|>"}),
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {
            "assets": {"tokenizer_config_path": str(config_path)},
            "options": {},
        }
    )

    assert result == {
        "control_tokens_chat_template": ["<token_a>", "<|token_b|>"],
        "control_tokens_wrapper_tool": [],
        "chat_template_literals_count": 2,
        "wrapper_tool_markers_count": 0,
    }


def test_extract_safe_tokenization_catalog_allows_template_without_tokenizer_config(
    tmp_path: Path,
) -> None:
    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("prefix <|template_only|> suffix", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {"chat_template_path": str(template_path)},
            "options": {},
        }
    )

    assert result == {
        "control_tokens_chat_template": ["<|template_only|>"],
        "control_tokens_wrapper_tool": [],
        "chat_template_literals_count": 1,
        "wrapper_tool_markers_count": 0,
    }


def test_extract_safe_tokenization_catalog_requires_an_asset_path() -> None:
    try:
        extract_safe_tokenization_catalog({"assets": {}, "options": {}})
    except ValueError as exc:
        assert str(exc) == "assets must include tokenizer_config_path or chat_template_path"
    else:
        raise AssertionError("expected ValueError")


def test_extract_safe_tokenization_catalog_allows_wrapper_markers_without_template(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    result = extract_safe_tokenization_catalog(
        {
            "assets": {"tokenizer_config_path": str(config_path)},
            "options": {"tool_parser_type": "qwen2"},
        }
    )

    assert result == {
        "control_tokens_chat_template": [],
        "control_tokens_wrapper_tool": ["</tool_call>", "<tool_call>"],
        "chat_template_literals_count": 0,
        "wrapper_tool_markers_count": 2,
    }


def test_extract_safe_tokenization_catalog_config_list_prefers_default(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text(
        json.dumps(
            {
                "chat_template": [
                    {"name": "non-default", "template": "<first>"},
                    {"name": "default", "template": "<chosen_default>"},
                ]
            }
        ),
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {"assets": {"tokenizer_config_path": str(config_path)}, "options": {}}
    )

    assert result["control_tokens_chat_template"] == ["<chosen_default>"]


def test_extract_chat_template_literals_rejects_malformed_template(tmp_path: Path) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text("{}", encoding="utf-8")

    template_path = tmp_path / "chat_template.jinja"
    template_path.write_text("{# broken", encoding="utf-8")

    try:
        extract_chat_template_literals(config_path, template_path)
    except ValueError as exc:
        assert "chat template asset is invalid:" in str(exc)
    else:
        raise AssertionError("expected ValueError")


def test_extract_safe_tokenization_catalog_config_list_uses_first_without_default(
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "tokenizer_config.json"
    config_path.write_text(
        json.dumps(
            {
                "chat_template": [
                    {"name": "first", "template": "<chosen_first>"},
                    {"name": "second", "template": "<second>"},
                ]
            }
        ),
        encoding="utf-8",
    )

    result = extract_safe_tokenization_catalog(
        {"assets": {"tokenizer_config_path": str(config_path)}, "options": {}}
    )

    assert result["control_tokens_chat_template"] == ["<chosen_first>"]
