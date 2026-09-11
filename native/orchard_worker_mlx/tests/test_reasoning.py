from __future__ import annotations

import ast
import json
from pathlib import Path
from typing import Any

import pytest

from orchard_worker_mlx.reasoning import (
    _PRODUCTION_PROMPT_OPENED_RENDER_CONTRACTS,
    StatefulReasoningParser,
    prompt_opened_reasoning,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS_DIR = REPO_ROOT / "proto/orchard/worker/v1/fixtures/reasoning"
REASONING_MODULE = REPO_ROOT / "native/orchard_worker_mlx/src/orchard_worker_mlx/reasoning.py"


def load_corpus() -> list[tuple[Path, dict[str, Any]]]:
    documents: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(CORPUS_DIR.glob("*.json")):
        with path.open(encoding="utf-8") as fixture_file:
            document = json.load(fixture_file)
        assert isinstance(document, dict), f"{path} must contain an object"
        documents.append((path, document))
    return documents


CORPUS = load_corpus()
CASES = [(path, document, case) for path, document in CORPUS for case in document.get("cases", [])]
CASE_IDS = [str(case["id"]) for _path, _document, case in CASES]


def case_id(case: dict[str, Any]) -> str:
    return str(case["id"])


def corpus_parser(document: dict[str, Any], case: dict[str, Any]) -> StatefulReasoningParser:
    return StatefulReasoningParser(
        parser_family=document["parser_family"],
        parser_version=document["parser_version"],
        generation_policy=case["generation_policy"],
        render_contract=document["render_contract"],
        render_contract_version=document["render_contract_version"],
        synthetic_prompt_opened_render_contracts=tuple(
            tuple(pair) for pair in document.get("synthetic_prompt_opened_render_contracts", [])
        ),
    )


def tagged_pair_parser(**overrides: Any) -> StatefulReasoningParser:
    arguments: dict[str, Any] = {
        "parser_family": "tagged_pair",
        "parser_version": "v1",
        "generation_policy": "model_default",
        "render_contract": "synthetic.tagged_pair",
        "render_contract_version": "v1",
    }
    arguments.update(overrides)
    return StatefulReasoningParser(**arguments)


@pytest.mark.parametrize(("path", "document", "case"), CASES, ids=CASE_IDS)
def test_reasoning_corpus_cases(
    path: Path,
    document: dict[str, Any],
    case: dict[str, Any],
) -> None:
    assert document["schema_version"] == "reasoning-corpus/v1", path
    parser = corpus_parser(document, case)

    parts: list[str] = []
    for chunk in case["chunks"]:
        parts.append(parser.push(chunk).final_text)
        assert len(parser.snapshot().pending_marker) < len("</think>")

    terminal = parser.finish(case["terminal"])
    parts.append(terminal.final_text)
    output = "".join(parts)
    expected = case["expected"]

    assert output == expected["final_text"]
    assert terminal.failure_code == expected["failure_code"]
    assert terminal.failure_reason == expected["failure_reason"]

    snapshot = parser.snapshot()
    assert snapshot.pending_marker == ""
    assert not snapshot.has_unclassified_text
    assert not hasattr(snapshot, "reasoning_text")
    _assert_boundary(case.get("boundary"), output)


@pytest.mark.parametrize(("path", "document", "case"), CASES, ids=CASE_IDS)
def test_reasoning_corpus_cases_do_not_depend_on_chunk_segmentation(
    path: Path,
    document: dict[str, Any],
    case: dict[str, Any],
) -> None:
    """Re-split every case so a later violation cannot expose earlier bytes."""
    joined = "".join(case["chunks"])
    expected = case["expected"]

    for segmentation in ([joined], list(joined)):
        parser = corpus_parser(document, case)
        output = "".join(parser.push(chunk).final_text for chunk in segmentation)
        terminal = parser.finish(case["terminal"])
        output += terminal.final_text

        assert output == expected["final_text"], (path, len(segmentation))
        assert terminal.failure_code == expected["failure_code"], (path, len(segmentation))
        assert terminal.failure_reason == expected["failure_reason"], (path, len(segmentation))


def _assert_boundary(boundary: dict[str, str] | None, output: str) -> None:
    if boundary is None:
        return
    assert output == boundary["downstream_input"]
    if boundary["kind"] == "tool":
        return
    assert boundary["kind"] == "stop"
    assert output.split(boundary["sequence"], 1)[0] == boundary["after_stop"]


def test_corpus_matrix_is_complete_and_case_ids_are_unique() -> None:
    assert CORPUS, "the reasoning corpus must contain at least one fixture"
    required_coverage = {
        "policy:model_default",
        "policy:disabled",
        "policy:enabled",
        "split_marker",
        "chunk_boundary",
        "chunk_invariance",
        "unicode",
        "nested_marker",
        "stray_marker",
        "unclosed_marker",
        "late_open_marker",
        "incomplete_marker",
        "residual_marker_flush",
        "tool_boundary",
        "stop_boundary",
        "terminal:completed",
        "terminal:stop",
        "terminal:length",
        "terminal:cancelled",
        "terminal:deadline",
        "leakage",
        "no_marker",
    }
    family_required_coverage = {
        "tagged_pair": {"whitespace_prefix"},
        "prompt_opened": set[str](),
    }
    ids: set[str] = set()

    for path, document in CORPUS:
        family = document["parser_family"]
        assert family in family_required_coverage, path
        assert document["parser_version"] == "v1", path
        coverage = {label for case in document["cases"] for label in case["coverage"]}
        assert required_coverage <= coverage, path
        assert family_required_coverage[family] <= coverage, path
        for case in document["cases"]:
            assert case_id(case) not in ids
            ids.add(case_id(case))

    assert {document["parser_family"] for _path, document in CORPUS} == {
        "tagged_pair",
        "prompt_opened",
    }


def test_prompt_opened_requires_an_exact_closed_render_mapping() -> None:
    assert not prompt_opened_reasoning("synthetic.prompt_opened", "v1")
    assert prompt_opened_reasoning(
        "synthetic.prompt_opened",
        "v1",
        synthetic_prompt_opened_render_contracts=(("synthetic.prompt_opened", "v1"),),
    )
    with pytest.raises(ValueError, match="unqualified_prompt_opened_render_contract"):
        StatefulReasoningParser(
            parser_family="prompt_opened",
            parser_version="v1",
            generation_policy="model_default",
            render_contract="synthetic.prompt_opened",
            render_contract_version="v1",
        )


def test_production_prompt_opened_render_contract_table_stays_dormant() -> None:
    assert _PRODUCTION_PROMPT_OPENED_RENDER_CONTRACTS == frozenset()


@pytest.mark.parametrize(
    ("overrides", "reason"),
    [
        ({"generation_policy": "always"}, "unsupported_generation_policy"),
        ({"parser_version": "v2"}, "unsupported_parser_version"),
        ({"parser_family": "harmony"}, "unsupported_parser_family"),
        (
            {"synthetic_prompt_opened_render_contracts": (("synthetic.tagged_pair", "v1"),)},
            "parser_family_render_contract_mismatch",
        ),
        (
            {"parser_family": "prompt_opened", "render_contract": "synthetic.prompt_opened"},
            "unqualified_prompt_opened_render_contract",
        ),
    ],
)
def test_constructor_admission_guards_fail_closed(
    overrides: dict[str, Any],
    reason: str,
) -> None:
    with pytest.raises(ValueError, match=reason):
        tagged_pair_parser(**overrides)


def test_unsupported_terminal_kind_fails_closed() -> None:
    with pytest.raises(ValueError, match="unsupported_parser_terminal"):
        tagged_pair_parser().finish("truncated")


def test_non_string_chunk_fails_closed() -> None:
    with pytest.raises(TypeError, match="decoded_chunk_must_be_str"):
        tagged_pair_parser().push(b"answer")  # type: ignore[arg-type]


def test_parser_rejects_reuse_after_its_terminal() -> None:
    parser = tagged_pair_parser()
    assert parser.finish("completed").ok
    with pytest.raises(RuntimeError, match="parser_already_finished"):
        parser.push("more")
    with pytest.raises(RuntimeError, match="parser_already_finished"):
        parser.finish("completed")


def test_whitespace_before_an_open_marker_is_framing_not_output() -> None:
    framed = tagged_pair_parser()
    assert framed.push(" \n<think>private</think>answer").final_text == "answer"
    assert framed.finish("completed").ok

    unframed = tagged_pair_parser()
    assert unframed.push("  ").final_text == ""
    terminal = unframed.finish("completed")
    assert terminal.ok
    assert terminal.final_text == "  "


def test_reasoning_parser_has_no_mlx_or_provider_imports() -> None:
    modules: set[str] = set()
    for node in ast.walk(ast.parse(REASONING_MODULE.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            modules.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            modules.add("." * node.level + (node.module or ""))

    assert modules == {
        "__future__",
        "collections.abc",
        "dataclasses",
        "orchard_worker_mlx.partial_markers",
    }
