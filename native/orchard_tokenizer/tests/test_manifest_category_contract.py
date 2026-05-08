from __future__ import annotations

import json
from pathlib import Path
from typing import Any, cast

from orchard_tokenizer import cli, safe_segmented

_CATEGORY_ENUM_KEY = "safe_tokenization.incompatibility_reason.category"
_TOKENIZER_CATEGORY_ENUM_KEY = "safe_tokenization.incompatibility_reason.tokenizer_categories"
_TEMPLATE_CATEGORY_ENUM_KEY = "safe_tokenization.incompatibility_reason.template_categories"
_HELPER_LOCAL_DIAGNOSTICS = frozenset(
    {"marker_collision", "marker_walk_mismatch", "catalog_hash_mismatch"}
)
_OUTER_ERROR_ENVELOPE_CATEGORIES = frozenset(
    {
        "safe_tokenization_incompatible_tokenizer",
        "safe_tokenization_incompatible_template",
        "safe_tokenization_marker_collision",
        "safe_tokenization_catalog_hash_mismatch",
    }
)


def test_manifest_category_fixture_matches_python_tokenizer_contracts() -> None:
    category_sets = manifest_category_sets()

    assert category_sets["all"] == sorted(category_sets["all"])
    assert category_sets["tokenizer"] == sorted(category_sets["tokenizer"])
    assert category_sets["template"] == sorted(category_sets["template"])

    all_categories = frozenset(category_sets["all"])
    tokenizer_categories = frozenset(category_sets["tokenizer"])
    template_categories = frozenset(category_sets["template"])

    assert all_categories == tokenizer_categories | template_categories
    assert tokenizer_categories.isdisjoint(template_categories)
    assert all_categories == cli._DETERMINISTIC_PREFLIGHT_INCOMPATIBILITIES
    assert all_categories == safe_segmented._CONTRACT_INCOMPATIBILITY_CATEGORIES
    assert tokenizer_categories == safe_segmented._TOKENIZER_INCOMPATIBILITY_CATEGORIES
    assert template_categories == safe_segmented._TEMPLATE_INCOMPATIBILITY_CATEGORIES

    assert all_categories.isdisjoint(_HELPER_LOCAL_DIAGNOSTICS)
    assert all_categories.isdisjoint(_OUTER_ERROR_ENVELOPE_CATEGORIES)


def manifest_category_sets() -> dict[str, list[str]]:
    fixture = cast(dict[str, Any], json.loads(manifest_schema_fixture_path().read_text()))
    assert fixture["version"] == 1
    category_enums = cast(dict[str, list[str]], fixture["category_enums"])

    return {
        "all": category_enums[_CATEGORY_ENUM_KEY],
        "tokenizer": category_enums[_TOKENIZER_CATEGORY_ENUM_KEY],
        "template": category_enums[_TEMPLATE_CATEGORY_ENUM_KEY],
    }


def manifest_schema_fixture_path() -> Path:
    return (
        Path(__file__).resolve().parents[3]
        / "apps"
        / "orchard_shared"
        / "test"
        / "fixtures"
        / "manifest_schema"
        / "v1.json"
    )
